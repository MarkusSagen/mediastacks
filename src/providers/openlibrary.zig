//! Open Library provider.
//!
//! Endpoints used:
//!   ISBN slim:   https://openlibrary.org/api/books?bibkeys=ISBN:{isbn}&format=json&jscmd=data
//!   ISBN deep:   https://openlibrary.org/api/books?bibkeys=ISBN:{isbn}&format=json&jscmd=details
//!   Search:      https://openlibrary.org/search.json?title=...&author=...
//!   Work:        https://openlibrary.org/works/{key}.json
//!   Editions:    https://openlibrary.org/works/{key}/editions.json?limit=50
//!
//! `lookup()` returns the slim per-edition record (one HTTP call). For the
//! web UI's "Fetch info" button we use `lookupRich()` which fans out to
//! the work and editions endpoints to surface alternative covers,
//! subjects, and sibling editions.

const std = @import("std");
const meta = @import("../core/metadata.zig");
const provider_iface = @import("provider.zig");
const http = @import("../util/http.zig");

/// A single edition of a work — one printing/imprint with its own ISBN.
/// Returned as part of `EnrichResult.editions`; not persisted on the
/// `books` row (those store the *user's* edition).
pub const Edition = struct {
    ol_key: ?[]const u8 = null, // e.g. "/books/OL12345M"
    isbn: ?[]const u8 = null,
    publisher: ?[]const u8 = null,
    published_year: ?u16 = null,
    language: ?[]const u8 = null,
    pages: ?u32 = null,
    cover_url: ?[]const u8 = null,
};

/// The full payload `lookupRich` returns: the merge-ready BookMetadata
/// (same shape as `lookup` returns) plus the work-level extras that the
/// UI needs in order to surface alternatives.
pub const EnrichResult = struct {
    metadata: meta.BookMetadata,
    work_key: ?[]const u8 = null, // e.g. "/works/OL12345W"
    /// Cover URLs gathered from the work record and from every edition
    /// in the work; de-duplicated, primary cover excluded.
    alt_cover_urls: []const []const u8 = &.{},
    /// Sibling editions of the same work.
    editions: []const Edition = &.{},
};

pub const OpenLibrary = struct {
    pub fn provider(self: *OpenLibrary) provider_iface.Provider {
        return .{
            .ctx = self,
            .name_str = "openlibrary",
            .lookup_fn = lookupShim,
        };
    }

    fn lookupShim(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        q: provider_iface.Query,
    ) !?meta.BookMetadata {
        const self: *OpenLibrary = @ptrCast(@alignCast(ctx));
        return self.lookup(allocator, io, q);
    }

    pub fn lookup(
        self: *OpenLibrary,
        allocator: std.mem.Allocator,
        io: std.Io,
        q: provider_iface.Query,
    ) !?meta.BookMetadata {
        _ = self;

        if (q.isbn) |isbn| {
            const url = try std.fmt.allocPrint(
                allocator,
                "https://openlibrary.org/api/books?bibkeys=ISBN:{s}&format=json&jscmd=data",
                .{isbn},
            );
            defer allocator.free(url);
            var resp = http.get(allocator, io, url, .{}) catch |err| switch (err) {
                error.HttpError, error.NotImplemented => return null,
                else => return err,
            };
            defer resp.deinit(allocator);
            if (resp.status != 200) return null;
            return parseIsbnPayload(allocator, isbn, resp.body);
        }

        if (q.title) |title| {
            const author_q = q.author orelse "";
            const escaped_title = try urlEncode(allocator, title);
            defer allocator.free(escaped_title);
            const escaped_author = try urlEncode(allocator, author_q);
            defer allocator.free(escaped_author);

            const url = try std.fmt.allocPrint(
                allocator,
                "https://openlibrary.org/search.json?title={s}&author={s}&limit=1",
                .{ escaped_title, escaped_author },
            );
            defer allocator.free(url);

            var resp = http.get(allocator, io, url, .{}) catch |err| switch (err) {
                error.HttpError, error.NotImplemented => return null,
                else => return err,
            };
            defer resp.deinit(allocator);
            if (resp.status != 200) return null;
            return parseSearchPayload(allocator, resp.body);
        }

        return null;
    }

    /// Like `lookup` but follows the work/editions links to return the
    /// full picture. Up to three HTTP calls per invocation; any of them
    /// can fail and we degrade gracefully — the user always gets at
    /// least the slim metadata `lookup` would have returned.
    pub fn lookupRich(
        self: *OpenLibrary,
        allocator: std.mem.Allocator,
        io: std.Io,
        q: provider_iface.Query,
    ) !?EnrichResult {
        _ = self;

        // Step 1: get a starting BookMetadata + (when possible) the
        // work key. ISBN path uses both `jscmd=data` and `jscmd=details`
        // — data has nice human strings, details has the work pointer.
        var base_md: ?meta.BookMetadata = null;
        var work_key: ?[]const u8 = null;
        var isbn_for_followup: ?[]const u8 = null;

        if (q.isbn) |isbn| {
            isbn_for_followup = isbn;

            const data_url = try std.fmt.allocPrint(
                allocator,
                "https://openlibrary.org/api/books?bibkeys=ISBN:{s}&format=json&jscmd=data",
                .{isbn},
            );
            defer allocator.free(data_url);
            if (httpGetOk(allocator, io, data_url)) |body| {
                defer allocator.free(body);
                base_md = parseIsbnPayload(allocator, isbn, body) catch null;
            }

            const det_url = try std.fmt.allocPrint(
                allocator,
                "https://openlibrary.org/api/books?bibkeys=ISBN:{s}&format=json&jscmd=details",
                .{isbn},
            );
            defer allocator.free(det_url);
            if (httpGetOk(allocator, io, det_url)) |body| {
                defer allocator.free(body);
                const det = parseDetailsPayload(allocator, isbn, body) catch
                    .{ .work_key = null, .md = null };
                work_key = det.work_key;
                if (det.md) |dm| {
                    if (base_md) |bm| {
                        base_md = try meta.BookMetadata.merge(allocator, bm, dm);
                    } else {
                        base_md = dm;
                    }
                }
            }
        } else if (q.title) |title| {
            // Search path. Pull the first doc and lift the work key from it.
            const author_q = q.author orelse "";
            const et = try urlEncode(allocator, title);
            defer allocator.free(et);
            const ea = try urlEncode(allocator, author_q);
            defer allocator.free(ea);
            const url = try std.fmt.allocPrint(
                allocator,
                "https://openlibrary.org/search.json?title={s}&author={s}&limit=1",
                .{ et, ea },
            );
            defer allocator.free(url);
            if (httpGetOk(allocator, io, url)) |body| {
                defer allocator.free(body);
                base_md = parseSearchPayload(allocator, body) catch null;
                work_key = extractFirstWorkKey(allocator, body) catch null;
            }
        }

        if (base_md == null and work_key == null) return null;

        // Step 2 (optional): work record for subjects/description/series.
        var alt_covers: std.ArrayList([]const u8) = .empty;
        if (work_key) |wk| {
            const wk_path = stripWorksPrefix(wk);
            const url = try std.fmt.allocPrint(
                allocator,
                "https://openlibrary.org/works/{s}.json",
                .{wk_path},
            );
            defer allocator.free(url);
            if (httpGetOk(allocator, io, url)) |body| {
                defer allocator.free(body);
                const info = parseWorkPayload(allocator, body) catch WorkInfo{};
                if (base_md == null) base_md = .{ .source = .openlibrary, .confidence = 0.7 };
                var bm = base_md.?;
                if (bm.series == null and info.series != null) bm.series = info.series;
                if (bm.description == null and info.description != null) bm.description = info.description;
                if (bm.subjects.len == 0 and info.subjects.len > 0) bm.subjects = info.subjects;
                base_md = bm;

                // Collect alt cover URLs from the work, skipping the
                // primary cover so we don't show it twice.
                for (info.cover_ids) |cid| {
                    const cover_url = try std.fmt.allocPrint(
                        allocator,
                        "https://covers.openlibrary.org/b/id/{d}-M.jpg",
                        .{cid},
                    );
                    if (bm.cover_path) |primary| {
                        if (std.mem.indexOf(u8, primary, cover_url[cover_url.len - 12 ..]) != null) {
                            allocator.free(cover_url);
                            continue;
                        }
                    }
                    try alt_covers.append(allocator, cover_url);
                }
            }
        }

        // Step 3 (optional): editions list.
        var editions: []const Edition = &.{};
        if (work_key) |wk| {
            const wk_path = stripWorksPrefix(wk);
            const url = try std.fmt.allocPrint(
                allocator,
                "https://openlibrary.org/works/{s}/editions.json?limit=50",
                .{wk_path},
            );
            defer allocator.free(url);
            if (httpGetOk(allocator, io, url)) |body| {
                defer allocator.free(body);
                editions = parseEditionsPayload(allocator, body, 50) catch &.{};

                // Promote a few unique edition covers into alt_covers
                // so the user gets visual alternatives even when the
                // work record has only one cover_id.
                var seen: std.StringHashMap(void) = .init(allocator);
                defer seen.deinit();
                for (alt_covers.items) |u| try seen.put(u, {});
                for (editions) |e| {
                    const u = e.cover_url orelse continue;
                    if (seen.contains(u)) continue;
                    try seen.put(u, {});
                    try alt_covers.append(allocator, u);
                    if (alt_covers.items.len >= 12) break;
                }
            }
        }

        return .{
            .metadata = base_md orelse .{ .source = .openlibrary, .confidence = 0.6 },
            .work_key = work_key,
            .alt_cover_urls = try alt_covers.toOwnedSlice(allocator),
            .editions = editions,
        };
    }
};

/// Convenience: HTTP GET, return the body on 200, null on anything else.
/// We keep error handling internal so callers don't have to thread
/// error unions through every step of the orchestrator.
fn httpGetOk(allocator: std.mem.Allocator, io: std.Io, url: []const u8) ?[]u8 {
    var resp = http.get(allocator, io, url, .{}) catch return null;
    if (resp.status != 200) {
        resp.deinit(allocator);
        return null;
    }
    return resp.body;
}

fn stripWorksPrefix(key: []const u8) []const u8 {
    const prefix = "/works/";
    if (std.mem.startsWith(u8, key, prefix)) return key[prefix.len..];
    return key;
}

fn extractFirstWorkKey(allocator: std.mem.Allocator, body: []const u8) !?[]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const docs = parsed.value.object.get("docs") orelse return null;
    if (docs != .array or docs.array.items.len == 0) return null;
    const doc = docs.array.items[0];
    if (doc != .object) return null;
    const k = doc.object.get("key") orelse return null;
    if (k != .string) return null;
    return try allocator.dupe(u8, k.string);
}

/// Minimal percent-encoder for URL query values.
fn urlEncode(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    for (s) |ch| {
        const safe = std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~';
        if (safe) {
            try buf.append(allocator, ch);
        } else if (ch == ' ') {
            try buf.append(allocator, '+');
        } else {
            const hex = "0123456789ABCDEF";
            try buf.append(allocator, '%');
            try buf.append(allocator, hex[ch >> 4]);
            try buf.append(allocator, hex[ch & 0x0f]);
        }
    }
    return buf.toOwnedSlice(allocator);
}

/// Parse Open Library's search.json response and return metadata for
/// the first matching doc. Confidence is dialled down a notch vs ISBN
/// lookup because title-search is fuzzier.
pub fn parseSearchPayload(
    allocator: std.mem.Allocator,
    body: []const u8,
) !?meta.BookMetadata {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return null;
    const docs_v = root.object.get("docs") orelse return null;
    if (docs_v != .array or docs_v.array.items.len == 0) return null;
    const doc_v = docs_v.array.items[0];
    if (doc_v != .object) return null;
    const doc = doc_v.object;

    var md: meta.BookMetadata = .{ .source = .openlibrary, .confidence = 0.6 };

    if (doc.get("title")) |t| {
        if (t == .string) md.title = try allocator.dupe(u8, t.string);
    }
    if (doc.get("first_publish_year")) |y| {
        if (y == .integer and y.integer >= 1000 and y.integer < 3000) {
            md.published_year = @intCast(y.integer);
        }
    }
    if (doc.get("author_name")) |an| {
        if (an == .array) {
            var authors_buf: std.ArrayList(meta.Author) = .empty;
            for (an.array.items) |a| {
                if (a != .string) continue;
                const author = try meta.Author.fromDisplay(allocator, a.string);
                try authors_buf.append(allocator, author);
            }
            md.authors = try authors_buf.toOwnedSlice(allocator);
        }
    }
    if (doc.get("isbn")) |is| {
        if (is == .array and is.array.items.len > 0) {
            // Prefer the first ISBN-13 (13 chars, all digits).
            for (is.array.items) |it| {
                if (it != .string) continue;
                if (it.string.len == 13) {
                    md.isbn = try allocator.dupe(u8, it.string);
                    break;
                }
            }
            if (md.isbn == null) {
                const first = is.array.items[0];
                if (first == .string) md.isbn = try allocator.dupe(u8, first.string);
            }
        }
    }
    if (doc.get("cover_i")) |ci| {
        if (ci == .integer) {
            md.cover_path = try std.fmt.allocPrint(
                allocator,
                "https://covers.openlibrary.org/b/id/{d}-L.jpg",
                .{ci.integer},
            );
        }
    }
    return md;
}

/// Parse Open Library's ISBN-keyed jscmd=data response.
/// Top-level shape: { "ISBN:9780...": { ...book... } }
pub fn parseIsbnPayload(
    allocator: std.mem.Allocator,
    isbn: []const u8,
    body: []const u8,
) !?meta.BookMetadata {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return null;

    var key_buf: [128]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "ISBN:{s}", .{isbn}) catch return null;

    const book_value = root.object.get(key) orelse return null;
    if (book_value != .object) return null;
    const book = book_value.object;

    var md: meta.BookMetadata = .{
        .source = .openlibrary,
        .confidence = 0.7,
        .isbn = try allocator.dupe(u8, isbn),
    };

    if (book.get("title")) |t| {
        if (t == .string) md.title = try allocator.dupe(u8, t.string);
    }

    if (book.get("publish_date")) |d| {
        if (d == .string and d.string.len >= 4) {
            // Open Library returns strings like "October 2024" or "2024".
            const yr = findYear(d.string);
            if (yr) |y| md.published_year = y;
        }
    }

    if (book.get("publishers")) |ps| {
        if (ps == .array and ps.array.items.len > 0) {
            const first = ps.array.items[0];
            if (first == .object) {
                if (first.object.get("name")) |n| {
                    if (n == .string) md.publisher = try allocator.dupe(u8, n.string);
                }
            }
        }
    }

    if (book.get("authors")) |authors_v| {
        if (authors_v == .array) {
            var authors_buf: std.ArrayList(meta.Author) = .empty;
            for (authors_v.array.items) |a| {
                if (a != .object) continue;
                const name_v = a.object.get("name") orelse continue;
                if (name_v != .string) continue;
                const author = try meta.Author.fromDisplay(allocator, name_v.string);
                try authors_buf.append(allocator, author);
            }
            md.authors = try authors_buf.toOwnedSlice(allocator);
        }
    }

    if (book.get("cover")) |cv| {
        if (cv == .object) {
            const url_v = cv.object.get("large") orelse cv.object.get("medium") orelse cv.object.get("small");
            if (url_v) |u| {
                if (u == .string) md.cover_path = try allocator.dupe(u8, u.string);
            }
        }
    }

    return md;
}

// ---- Rich enrichment ----------------------------------------------------

/// Parse a `jscmd=details` response and pull out the work key plus
/// anything we don't already get from `jscmd=data`. Returns null if the
/// requested ISBN is absent. The returned metadata is partial — callers
/// merge it with parseIsbnPayload's result for the final picture.
pub fn parseDetailsPayload(
    allocator: std.mem.Allocator,
    isbn: []const u8,
    body: []const u8,
) !struct { work_key: ?[]const u8, md: ?meta.BookMetadata } {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return .{ .work_key = null, .md = null };
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .work_key = null, .md = null };

    var key_buf: [128]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "ISBN:{s}", .{isbn}) catch
        return .{ .work_key = null, .md = null };
    const outer = parsed.value.object.get(key) orelse return .{ .work_key = null, .md = null };
    if (outer != .object) return .{ .work_key = null, .md = null };

    const details_v = outer.object.get("details") orelse return .{ .work_key = null, .md = null };
    if (details_v != .object) return .{ .work_key = null, .md = null };
    const details = details_v.object;

    var work_key: ?[]const u8 = null;
    if (details.get("works")) |ws| {
        if (ws == .array and ws.array.items.len > 0) {
            const first = ws.array.items[0];
            if (first == .object) {
                if (first.object.get("key")) |k| {
                    if (k == .string) work_key = try allocator.dupe(u8, k.string);
                }
            }
        }
    }

    var md: meta.BookMetadata = .{ .source = .openlibrary, .confidence = 0.75 };
    // (number_of_pages is captured per-edition in parseEditionsPayload;
    // BookMetadata has no `pages` field so we don't pull it here.)
    if (details.get("languages")) |ls| {
        if (ls == .array and ls.array.items.len > 0) {
            const first = ls.array.items[0];
            if (first == .object) {
                if (first.object.get("key")) |k| {
                    if (k == .string and std.mem.startsWith(u8, k.string, "/languages/")) {
                        md.language = try allocator.dupe(u8, k.string["/languages/".len..]);
                    }
                }
            }
        }
    }
    if (details.get("subjects")) |sj| {
        if (sj == .array) {
            md.subjects = try collectStringArray(allocator, sj.array.items, 24);
        }
    }
    if (details.get("covers")) |covers| {
        if (covers == .array and covers.array.items.len > 0) {
            const first = covers.array.items[0];
            if (first == .integer) {
                md.cover_path = try std.fmt.allocPrint(
                    allocator,
                    "https://covers.openlibrary.org/b/id/{d}-L.jpg",
                    .{first.integer},
                );
            }
        }
    }

    return .{ .work_key = work_key, .md = md };
}

/// Parse `/works/{key}.json` and extract subjects, description, series
/// (heuristic), and the full list of cover IDs (used as alt covers).
pub const WorkInfo = struct {
    subjects: []const []const u8 = &.{},
    description: ?[]const u8 = null,
    series: ?[]const u8 = null,
    cover_ids: []const i64 = &.{},
};

pub fn parseWorkPayload(allocator: std.mem.Allocator, body: []const u8) !WorkInfo {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return .{};
    defer parsed.deinit();
    if (parsed.value != .object) return .{};
    const work = parsed.value.object;

    var info: WorkInfo = .{};

    if (work.get("subjects")) |sj| {
        if (sj == .array) info.subjects = try collectStringArray(allocator, sj.array.items, 24);
    }

    if (work.get("description")) |d| {
        if (d == .string) {
            info.description = try allocator.dupe(u8, d.string);
        } else if (d == .object) {
            if (d.object.get("value")) |v| {
                if (v == .string) info.description = try allocator.dupe(u8, v.string);
            }
        }
    }

    // OL has no canonical series field on the work; some records expose
    // a "series" array of strings — pick the first if so.
    if (work.get("series")) |sv| {
        if (sv == .array and sv.array.items.len > 0) {
            const first = sv.array.items[0];
            if (first == .string) info.series = try allocator.dupe(u8, first.string);
        }
    }

    if (work.get("covers")) |cv| {
        if (cv == .array) {
            var ids: std.ArrayList(i64) = .empty;
            for (cv.array.items) |item| {
                if (item != .integer) continue;
                // OL marks placeholders as -1; skip.
                if (item.integer <= 0) continue;
                try ids.append(allocator, item.integer);
            }
            info.cover_ids = try ids.toOwnedSlice(allocator);
        }
    }

    return info;
}

/// Parse `/works/{key}/editions.json` and return a slice of editions
/// sorted by publish year (descending) so the latest printings surface
/// first. `cap` limits how many we keep, since OL works can have
/// hundreds of editions.
pub fn parseEditionsPayload(
    allocator: std.mem.Allocator,
    body: []const u8,
    cap: usize,
) ![]const Edition {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return &.{};
    defer parsed.deinit();
    if (parsed.value != .object) return &.{};
    const entries_v = parsed.value.object.get("entries") orelse return &.{};
    if (entries_v != .array) return &.{};

    var list: std.ArrayList(Edition) = .empty;
    for (entries_v.array.items) |entry| {
        if (entry != .object) continue;
        const e = entry.object;

        var ed: Edition = .{};

        if (e.get("key")) |k| if (k == .string) {
            ed.ol_key = try allocator.dupe(u8, k.string);
        };
        // Prefer ISBN-13, fall back to ISBN-10.
        ed.isbn = (try firstStringFromArray(allocator, e.get("isbn_13"))) orelse
            (try firstStringFromArray(allocator, e.get("isbn_10")));
        ed.publisher = try firstStringFromArray(allocator, e.get("publishers"));
        if (e.get("publish_date")) |d| {
            if (d == .string) ed.published_year = findYear(d.string);
        }
        if (e.get("number_of_pages")) |np| if (np == .integer and np.integer > 0) {
            ed.pages = @intCast(np.integer);
        };
        if (e.get("languages")) |ls| {
            if (ls == .array and ls.array.items.len > 0) {
                const first = ls.array.items[0];
                if (first == .object) {
                    if (first.object.get("key")) |k| {
                        if (k == .string and std.mem.startsWith(u8, k.string, "/languages/")) {
                            ed.language = try allocator.dupe(u8, k.string["/languages/".len..]);
                        }
                    }
                }
            }
        }
        if (e.get("covers")) |cv| {
            if (cv == .array) {
                for (cv.array.items) |item| {
                    if (item != .integer or item.integer <= 0) continue;
                    ed.cover_url = try std.fmt.allocPrint(
                        allocator,
                        "https://covers.openlibrary.org/b/id/{d}-M.jpg",
                        .{item.integer},
                    );
                    break;
                }
            }
        }

        // Skip records that look like noise (no ISBN AND no publisher AND no year).
        if (ed.isbn == null and ed.publisher == null and ed.published_year == null) continue;

        try list.append(allocator, ed);
        if (list.items.len >= cap) break;
    }

    // Stable sort by year desc, then publisher.
    const slice = try list.toOwnedSlice(allocator);
    std.sort.block(Edition, slice, {}, editionLessThan);
    return slice;
}

fn editionLessThan(_: void, a: Edition, b: Edition) bool {
    const ay = a.published_year orelse 0;
    const by = b.published_year orelse 0;
    if (ay != by) return ay > by; // newer first
    const ap = a.publisher orelse "";
    const bp = b.publisher orelse "";
    return std.mem.lessThan(u8, ap, bp);
}

fn firstStringFromArray(allocator: std.mem.Allocator, value: ?std.json.Value) !?[]const u8 {
    const v = value orelse return null;
    if (v != .array or v.array.items.len == 0) return null;
    const first = v.array.items[0];
    if (first != .string) return null;
    return try allocator.dupe(u8, first.string);
}

fn collectStringArray(
    allocator: std.mem.Allocator,
    items: []const std.json.Value,
    cap: usize,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (items) |item| {
        if (item != .string) continue;
        try out.append(allocator, try allocator.dupe(u8, item.string));
        if (out.items.len >= cap) break;
    }
    return out.toOwnedSlice(allocator);
}

fn findYear(s: []const u8) ?u16 {
    var i: usize = 0;
    while (i + 4 <= s.len) : (i += 1) {
        const slice = s[i .. i + 4];
        var all_digit = true;
        for (slice) |c| if (!std.ascii.isDigit(c)) { all_digit = false; break; };
        if (all_digit) {
            const y = std.fmt.parseInt(u16, slice, 10) catch continue;
            if (y >= 1000 and y < 3000) return y;
        }
    }
    return null;
}

// ---- Tests --------------------------------------------------------------

test "parseIsbnPayload extracts title and authors" {
    const fixture =
        \\{
        \\  "ISBN:9780545010221": {
        \\    "title": "Harry Potter and the Deathly Hallows",
        \\    "publish_date": "July 21, 2007",
        \\    "publishers": [{"name": "Arthur A. Levine Books"}],
        \\    "authors": [{"name": "J. K. Rowling"}]
        \\  }
        \\}
    ;
    const alloc = std.testing.allocator;
    const md_opt = try parseIsbnPayload(alloc, "9780545010221", fixture);
    try std.testing.expect(md_opt != null);
    const md = md_opt.?;
    defer if (md.title) |t| alloc.free(t);
    defer if (md.publisher) |p| alloc.free(p);
    defer if (md.isbn) |i| alloc.free(i);
    defer {
        for (md.authors) |a| {
            alloc.free(a.last);
            alloc.free(a.first);
            alloc.free(a.sort);
        }
        alloc.free(md.authors);
    }
    try std.testing.expectEqualStrings("Harry Potter and the Deathly Hallows", md.title.?);
    try std.testing.expectEqual(@as(u16, 2007), md.published_year.?);
    try std.testing.expectEqual(@as(usize, 1), md.authors.len);
    try std.testing.expectEqualStrings("Rowling", md.authors[0].last);
}

test "findYear pulls 4-digit year from text" {
    try std.testing.expectEqual(@as(u16, 2007), findYear("July 21, 2007").?);
    try std.testing.expectEqual(@as(u16, 1984), findYear("1984").?);
    try std.testing.expectEqual(@as(?u16, null), findYear("forever"));
}
