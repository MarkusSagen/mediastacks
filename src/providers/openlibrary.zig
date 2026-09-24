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
const clock = @import("../util/clock.zig");
const meta = @import("../core/metadata.zig");
const provider_iface = @import("provider.zig");
const http = @import("../util/http.zig");
const shutdown = @import("../util/shutdown.zig");
const fuzzy = @import("../util/fuzzy.zig");

const log = std.log.scoped(.ol);

/// One variant tried by the title-search ladder. The detail-panel
/// surfaces this so the user can see *why* a lookup either succeeded
/// (and which sanitization step won) or returned "no match" — without
/// having to crack open the server log.
///
/// All string slices are owned by the allocator passed to
/// `lookupRichDiag` (the per-request arena in the web layer).
pub const SearchAttempt = struct {
    title: []const u8,
    author: []const u8,
    num_docs: usize,
    chosen_title: ?[]const u8 = null,
    chosen_key: ?[]const u8 = null,
    /// `scoreDoc` of the chosen doc, or 0 when num_docs == 0.
    /// Useful as a confidence signal — author surname match = +1000.
    score: i64 = 0,
};

pub const DiagnosticResult = struct {
    result: ?EnrichResult,
    attempts: []SearchAttempt,
};

/// A single edition of a work — one printing/imprint with its own ISBN.
/// Returned as part of `EnrichResult.editions`; not persisted on the
/// `books` row (those store the *user's* edition).
pub const Edition = struct {
    ol_key: ?[]const u8 = null,
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
    work_key: ?[]const u8 = null,
    /// Cover URLs gathered from the work record and from every edition
    /// in the work; de-duplicated, primary cover excluded.
    alt_cover_urls: []const []const u8 = &.{},
    /// Sibling editions of the same work.
    editions: []const Edition = &.{},
    /// Top-N candidates from the winning search variant. The first
    /// candidate is always the chosen one (its metadata matches
    /// `EnrichResult.metadata`); the rest are alternates the user can
    /// click in the UI to override the diff editor's suggested column.
    candidates: []const Candidate = &.{},
};

/// One Open Library search-result candidate — enough fields for the
/// alternate-match picker (cover + title + author + year + score).
pub const Candidate = struct {
    title: ?[]const u8 = null,
    author: ?[]const u8 = null,
    work_key: ?[]const u8 = null,
    year: ?u16 = null,
    isbn: ?[]const u8 = null,
    cover_url: ?[]const u8 = null,
    score: i64 = 0,
    /// Full metadata for this candidate (subset of what
    /// `parseSearchPayloadAt` returns). When the user picks this
    /// candidate, the diff editor swaps its "suggested" column to
    /// these values.
    metadata: meta.BookMetadata = .{},
};

pub const OpenLibrary = struct {
    /// HTTP client used for every outbound call. Production wires
    /// `http.RealHttpClient` here; tests stash a `http.MockClient` so
    /// `lookup*` are exercised without real network traffic.
    http_client: http.HttpClient,

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
        _ = io;

        if (q.isbn) |isbn| {
            const url = try std.fmt.allocPrint(
                allocator,
                "https://openlibrary.org/api/books?bibkeys=ISBN:{s}&format=json&jscmd=data",
                .{isbn},
            );
            defer allocator.free(url);
            var resp = self.http_client.fetchGet(allocator, url, .{}) catch |err| switch (err) {
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
                "https://openlibrary.org/search.json?title={s}&author={s}&limit=10",
                .{ escaped_title, escaped_author },
            );
            defer allocator.free(url);

            var resp = self.http_client.fetchGet(allocator, url, .{}) catch |err| switch (err) {
                error.HttpError, error.NotImplemented => return null,
                else => return err,
            };
            defer resp.deinit(allocator);
            if (resp.status != 200) return null;
            return parseSearchPayload(allocator, resp.body, q);
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
        const diag = try self.lookupRichDiag(allocator, io, q);
        return diag.result;
    }

    /// Diagnostic variant of `lookupRich`. Returns the same result plus
    /// the list of search variants we tried (empty for the ISBN path —
    /// ISBN lookups are deterministic, no retry ladder needed).
    ///
    /// Callers that want to surface "we tried X then Y then Z" in the
    /// UI use this; the simpler `lookupRich` discards `attempts`.
    pub fn lookupRichDiag(
        self: *OpenLibrary,
        allocator: std.mem.Allocator,
        _: std.Io,
        q: provider_iface.Query,
    ) !DiagnosticResult {
        log.debug(
            "lookupRichDiag isbn={?s} title={?s} author={?s}",
            .{ q.isbn, q.title, q.author },
        );

        var base_md: ?meta.BookMetadata = null;
        var work_key: ?[]const u8 = null;
        var isbn_for_followup: ?[]const u8 = null;
        var attempts: []SearchAttempt = &.{};
        var search_candidates: []const Candidate = &.{};

        if (q.isbn) |isbn| {
            isbn_for_followup = isbn;

            const data_url = try std.fmt.allocPrint(
                allocator,
                "https://openlibrary.org/api/books?bibkeys=ISBN:{s}&format=json&jscmd=data",
                .{isbn},
            );
            defer allocator.free(data_url);
            if (httpGetOk(self.http_client, allocator, data_url)) |body| {
                defer allocator.free(body);
                base_md = parseIsbnPayload(allocator, isbn, body) catch null;
                if (base_md == null) {
                    log.debug("ISBN {s} (jscmd=data): no `ISBN:{s}` key in payload", .{ isbn, isbn });
                }
            }

            const det_url = try std.fmt.allocPrint(
                allocator,
                "https://openlibrary.org/api/books?bibkeys=ISBN:{s}&format=json&jscmd=details",
                .{isbn},
            );
            defer allocator.free(det_url);
            if (httpGetOk(self.http_client, allocator, det_url)) |body| {
                defer allocator.free(body);
                const det = parseDetailsPayload(allocator, isbn, body) catch DetailsResult{};
                work_key = det.work_key;
                if (det.md) |dm| {
                    if (base_md) |bm| {
                        base_md = try meta.BookMetadata.merge(allocator, bm, dm);
                    } else {
                        base_md = dm;
                    }
                }
            }
        } else if (q.title != null) {
            const ladder = try searchLadder(self.http_client, allocator, q);
            attempts = ladder.attempts;
            if (ladder.body) |body| {
                defer allocator.free(body);
                base_md = parseSearchPayloadAt(allocator, body, ladder.idx) catch null;
                work_key = extractWorkKeyAt(allocator, body, ladder.idx) catch null;
                search_candidates = parseSearchCandidates(allocator, body, q, ladder.idx, 6) catch &.{};
            }
        }

        if (base_md == null and work_key == null) {
            log.debug("lookupRichDiag: no match (attempts={d})", .{attempts.len});
            return .{ .result = null, .attempts = attempts };
        }

        var alt_covers: std.ArrayList([]const u8) = .empty;
        if (work_key) |wk| {
            const wk_path = stripWorksPrefix(wk);
            const url = try std.fmt.allocPrint(
                allocator,
                "https://openlibrary.org/works/{s}.json",
                .{wk_path},
            );
            defer allocator.free(url);
            if (httpGetOk(self.http_client, allocator, url)) |body| {
                defer allocator.free(body);
                const info = parseWorkPayload(allocator, body) catch WorkInfo{};
                if (base_md == null) base_md = .{ .source = .openlibrary, .confidence = 0.7 };
                var bm = base_md.?;
                if (bm.series == null and info.series != null) bm.series = info.series;
                if (bm.description == null and info.description != null) bm.description = info.description;
                if (bm.subjects.len == 0 and info.subjects.len > 0) bm.subjects = info.subjects;
                base_md = bm;

                for (info.cover_ids) |cid| {
                    if (alt_covers.items.len >= 3) break;
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

        var editions: []const Edition = &.{};
        if (work_key) |wk| {
            const wk_path = stripWorksPrefix(wk);
            const url = try std.fmt.allocPrint(
                allocator,
                "https://openlibrary.org/works/{s}/editions.json?limit=50",
                .{wk_path},
            );
            defer allocator.free(url);
            if (httpGetOk(self.http_client, allocator, url)) |body| {
                defer allocator.free(body);
                editions = parseEditionsPayload(allocator, body, 50) catch &.{};

                var seen: std.StringHashMap(void) = .init(allocator);
                defer seen.deinit();
                for (alt_covers.items) |u| try seen.put(u, {});
                for (editions) |e| {
                    if (alt_covers.items.len >= 3) break;
                    const u = e.cover_url orelse continue;
                    if (seen.contains(u)) continue;
                    try seen.put(u, {});
                    try alt_covers.append(allocator, u);
                }
            }
        }

        const enriched: EnrichResult = .{
            .metadata = base_md orelse .{ .source = .openlibrary, .confidence = 0.6 },
            .work_key = work_key,
            .alt_cover_urls = try alt_covers.toOwnedSlice(allocator),
            .editions = editions,
            .candidates = search_candidates,
        };
        log.debug(
            "lookupRichDiag: ok work_key={?s} editions={d} alt_covers={d}",
            .{ enriched.work_key, enriched.editions.len, enriched.alt_cover_urls.len },
        );
        return .{ .result = enriched, .attempts = attempts };
    }

    /// Page through `/works/<key>/editions.json` and return the next
    /// batch of unique cover URLs. Backs the `GET /api/books/:id/covers`
    /// endpoint — lookupRich() only returns 3 covers up front so the
    /// detail strip stays one tidy row; this fetches more on demand.
    ///
    /// Walks editions in fetch batches of `batch` (default 25). Stops as
    /// soon as we have `limit` URLs that aren't in `seen`, or after
    /// `max_batches` rounds (so a pathological work can't lock up the
    /// request).
    pub fn lookupMoreCovers(
        self: *OpenLibrary,
        allocator: std.mem.Allocator,
        _: std.Io,
        work_key: []const u8,
        offset: usize,
        limit: usize,
        seen: []const []const u8,
    ) !MoreCoversResult {
        const batch: usize = 25;
        const max_batches: usize = 3;

        const wk_path = stripWorksPrefix(work_key);

        var seen_map: std.StringHashMap(void) = .init(allocator);
        defer seen_map.deinit();
        for (seen) |s| try seen_map.put(s, {});

        var urls: std.ArrayList([]const u8) = .empty;
        var cur_offset: usize = offset;
        var rounds: usize = 0;
        var exhausted = false;

        while (rounds < max_batches and urls.items.len < limit) : (rounds += 1) {
            const url = try std.fmt.allocPrint(
                allocator,
                "https://openlibrary.org/works/{s}/editions.json?limit={d}&offset={d}",
                .{ wk_path, batch, cur_offset },
            );
            defer allocator.free(url);

            const body = httpGetOk(self.http_client, allocator, url) orelse break;
            defer allocator.free(body);

            const batch_result = parseEditionCoverBatch(allocator, body) catch break;
            cur_offset += batch_result.entry_count;

            for (batch_result.urls) |u| {
                if (seen_map.contains(u)) {
                    allocator.free(u);
                    continue;
                }
                try seen_map.put(u, {});
                try urls.append(allocator, u);
                if (urls.items.len >= limit) break;
            }
            allocator.free(batch_result.urls);

            if (batch_result.entry_count < batch) {
                exhausted = true;
                break;
            }
        }

        return .{
            .urls = try urls.toOwnedSlice(allocator),
            .next_offset = cur_offset,
            .exhausted = exhausted,
        };
    }
};

pub const MoreCoversResult = struct {
    urls: []const []const u8,
    next_offset: usize,
    exhausted: bool,
};

/// Outcome of one variant in the search ladder.
const SearchVariantOutcome = struct {
    /// Owned response body if the request hit 200, else null. Caller
    /// frees if it doesn't keep the body for downstream use.
    body: ?[]u8,
    /// Index into `body.docs[]` chosen by `chooseBestSearchDoc`. Only
    /// meaningful when `body != null`.
    idx: usize,
    /// What the user-facing diagnostic should show for this variant.
    attempt: SearchAttempt,
};

const LadderResult = struct {
    body: ?[]u8,
    idx: usize,
    attempts: []SearchAttempt,
};

/// Run the title-search retry ladder. Stops at the first variant that
/// returns ≥1 doc — the assumption is that Open Library's `search.json`
/// returns zero docs only when the query is decorated beyond its
/// fuzzy-match tolerance (subtitle + trailing parens are the usual
/// culprits), not when there's a "soft" mismatch we should fall through.
///
/// Variants tried (in order):
///   1. Title as given + author.
///   2. Normalized title (subtitle stripped, trailing parens stripped) +
///      author — only when normalization actually changed the title.
///   3. Normalized title with no `author=` filter — only when an author
///      *was* supplied (otherwise variant 3 == variant 2).
///
/// Returns the body from the first variant that yielded docs (caller
/// owns and must free), or null if all variants returned 0 docs.
fn searchLadder(
    client: http.HttpClient,
    allocator: std.mem.Allocator,
    q: provider_iface.Query,
) !LadderResult {
    var attempts: std.ArrayList(SearchAttempt) = .empty;
    errdefer attempts.deinit(allocator);

    const title_orig = q.title orelse return .{
        .body = null,
        .idx = 0,
        .attempts = try attempts.toOwnedSlice(allocator),
    };
    const author_orig = q.author orelse "";

    const normalized = try normalizeQueryTitle(allocator, title_orig);
    defer allocator.free(normalized);
    const normalized_differs = normalized.len > 0 and !std.mem.eql(u8, normalized, title_orig);

    if (try runSearchVariant(client, allocator, title_orig, author_orig, q)) |outcome| {
        try attempts.append(allocator, outcome.attempt);
        if (outcome.body) |b| return .{
            .body = b,
            .idx = outcome.idx,
            .attempts = try attempts.toOwnedSlice(allocator),
        };
    }

    if (normalized_differs) {
        if (try runSearchVariant(client, allocator, normalized, author_orig, q)) |outcome| {
            try attempts.append(allocator, outcome.attempt);
            if (outcome.body) |b| return .{
                .body = b,
                .idx = outcome.idx,
                .attempts = try attempts.toOwnedSlice(allocator),
            };
        }
    }

    if (author_orig.len > 0) {
        const search_title = if (normalized_differs) normalized else title_orig;
        if (try runSearchVariant(client, allocator, search_title, "", q)) |outcome| {
            try attempts.append(allocator, outcome.attempt);
            if (outcome.body) |b| return .{
                .body = b,
                .idx = outcome.idx,
                .attempts = try attempts.toOwnedSlice(allocator),
            };
        }
    }

    return .{
        .body = null,
        .idx = 0,
        .attempts = try attempts.toOwnedSlice(allocator),
    };
}

/// One round-trip to `search.json`. Returns null when the HTTP call
/// failed (network/non-200) — distinguishes that from "200 with 0 docs"
/// so the ladder can decide whether to retry. The returned `attempt`
/// is always populated so the user sees what was tried.
fn runSearchVariant(
    client: http.HttpClient,
    allocator: std.mem.Allocator,
    title: []const u8,
    author: []const u8,
    q: provider_iface.Query,
) !?SearchVariantOutcome {
    const et = try urlEncode(allocator, title);
    defer allocator.free(et);
    const ea = try urlEncode(allocator, author);
    defer allocator.free(ea);
    const url = try std.fmt.allocPrint(
        allocator,
        "https://openlibrary.org/search.json?title={s}&author={s}&limit=10",
        .{ et, ea },
    );
    defer allocator.free(url);

    var attempt: SearchAttempt = .{
        .title = try allocator.dupe(u8, title),
        .author = try allocator.dupe(u8, author),
        .num_docs = 0,
    };

    const body = httpGetOk(client, allocator, url) orelse {
        log.debug("search variant title=\"{s}\" author=\"{s}\": HTTP failure", .{ title, author });
        return .{ .body = null, .idx = 0, .attempt = attempt };
    };

    const stats = inspectSearchBody(allocator, body, q) catch SearchStats{};
    attempt.num_docs = stats.num_docs;
    attempt.chosen_title = if (stats.chosen_title) |t| try allocator.dupe(u8, t) else null;
    attempt.chosen_key = if (stats.chosen_key) |k| try allocator.dupe(u8, k) else null;
    attempt.score = stats.score;

    log.debug(
        "search variant title=\"{s}\" author=\"{s}\" → docs={d} chose={?s} score={d}",
        .{ title, author, attempt.num_docs, attempt.chosen_title, attempt.score },
    );

    if (attempt.num_docs == 0) {
        allocator.free(body);
        return .{ .body = null, .idx = 0, .attempt = attempt };
    }
    return .{ .body = body, .idx = stats.chosen_idx, .attempt = attempt };
}

const SearchStats = struct {
    num_docs: usize = 0,
    chosen_idx: usize = 0,
    chosen_title: ?[]const u8 = null,
    chosen_key: ?[]const u8 = null,
    score: i64 = 0,
};

fn inspectSearchBody(
    allocator: std.mem.Allocator,
    body: []const u8,
    q: provider_iface.Query,
) !SearchStats {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return SearchStats{};
    defer parsed.deinit();
    if (parsed.value != .object) return SearchStats{};
    const docs_v = parsed.value.object.get("docs") orelse return SearchStats{};
    if (docs_v != .array) return SearchStats{};
    const docs = docs_v.array.items;
    if (docs.len == 0) return SearchStats{};

    var idx: usize = 0;
    var best_score: i64 = std.math.minInt(i64);
    for (docs, 0..) |doc, i| {
        if (doc != .object) continue;
        const s = scoreDoc(doc.object, q);
        if (s > best_score) {
            best_score = s;
            idx = i;
        }
    }

    var stats: SearchStats = .{
        .num_docs = docs.len,
        .chosen_idx = idx,
        .score = best_score,
    };

    if (docs[idx] == .object) {
        if (docs[idx].object.get("title")) |t| {
            if (t == .string) stats.chosen_title = t.string;
        }
        if (docs[idx].object.get("key")) |k| {
            if (k == .string) stats.chosen_key = k.string;
        }
    }

    return stats;
}

/// Strip decoration from an Open Library search title query.
///
/// OL's `search.json` is fuzzy on word order but intolerant of
/// subtitle/series markers in the title field. Stripping the subtitle
/// (the part after the first `:`) and any trailing ` (...)` block
/// unblocks lookups like "A Little Hatred: Book One (The Age of
/// Madness)" → "A Little Hatred".
///
/// Returns an owned slice (always allocated, even when the result
/// equals the input — keeps the call site's free-pattern uniform).
pub fn normalizeQueryTitle(allocator: std.mem.Allocator, title: []const u8) ![]u8 {
    var slice = std.mem.trim(u8, title, " \t");

    while (true) {
        var end = slice.len;
        while (end > 0 and (slice[end - 1] == ' ' or slice[end - 1] == '\t')) end -= 1;
        if (end == 0 or slice[end - 1] != ')') break;
        var depth: i32 = 1;
        var i = end - 1;
        var open: ?usize = null;
        while (i > 0) {
            i -= 1;
            const c = slice[i];
            if (c == ')') depth += 1;
            if (c == '(') {
                depth -= 1;
                if (depth == 0) {
                    open = i;
                    break;
                }
            }
        }
        if (open) |o| {
            slice = std.mem.trim(u8, slice[0..o], " \t");
        } else break;
    }

    if (std.mem.indexOfScalar(u8, slice, ':')) |colon| {
        if (colon >= 3) {
            slice = std.mem.trim(u8, slice[0..colon], " \t");
        }
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var prev_space = false;
    for (slice) |ch| {
        const is_space = ch == ' ' or ch == '\t';
        if (is_space) {
            if (!prev_space and out.items.len > 0) try out.append(allocator, ' ');
            prev_space = true;
        } else {
            try out.append(allocator, ch);
            prev_space = false;
        }
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
        _ = out.pop();
    }
    return out.toOwnedSlice(allocator);
}

/// Lighter sibling of `parseEditionsPayload` for the cover paginator:
/// returns just the cover URLs out of every entry that has one, plus
/// the total entry count (used by the caller to decide whether the
/// edition stream is exhausted). Unlike `parseEditionsPayload`, this
/// keeps entries that lack ISBN/publisher/year — for cover discovery,
/// any edition with a cover is worth surfacing.
const BatchCoverResult = struct {
    urls: []const []const u8,
    entry_count: usize,
};

fn parseEditionCoverBatch(
    allocator: std.mem.Allocator,
    body: []const u8,
) !BatchCoverResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return .{ .urls = &.{}, .entry_count = 0 };
    defer parsed.deinit();
    if (parsed.value != .object)
        return .{ .urls = &.{}, .entry_count = 0 };
    const entries_v = parsed.value.object.get("entries") orelse
        return .{ .urls = &.{}, .entry_count = 0 };
    if (entries_v != .array)
        return .{ .urls = &.{}, .entry_count = 0 };

    var urls: std.ArrayList([]const u8) = .empty;
    for (entries_v.array.items) |entry| {
        if (entry != .object) continue;
        const covers = entry.object.get("covers") orelse continue;
        if (covers != .array) continue;
        for (covers.array.items) |c| {
            if (c != .integer or c.integer <= 0) continue;
            const u = try std.fmt.allocPrint(
                allocator,
                "https://covers.openlibrary.org/b/id/{d}-M.jpg",
                .{c.integer},
            );
            try urls.append(allocator, u);
            break;
        }
    }

    return .{
        .urls = try urls.toOwnedSlice(allocator),
        .entry_count = entries_v.array.items.len,
    };
}

/// GET with exponential backoff on transient failures. Retries up to
/// 3 times with 250ms / 750ms / 2s sleeps between attempts. Returns
/// null on a terminal 4xx (404/410 = no record, not worth retrying),
/// or on the final transient failure (network error / 5xx). The
/// shutdown atomic is checked before each backoff so Ctrl+C during a
/// batch doesn't have to wait out a 2s sleep.
fn httpGetOk(client: http.HttpClient, allocator: std.mem.Allocator, url: []const u8) ?[]u8 {
    const delays_ms = [_]u64{ 0, 250, 750, 2000 };
    var i: usize = 0;
    while (i < delays_ms.len) : (i += 1) {
        if (delays_ms[i] > 0) {
            if (shutdown.isRequested()) return null;
            var remaining = delays_ms[i];
            while (remaining > 0) {
                if (shutdown.isRequested()) return null;
                const chunk: u64 = if (remaining > 250) 250 else remaining;
                clock.sleepMs(chunk);
                remaining -= chunk;
            }
        }
        var resp = client.fetchGet(allocator, url, .{}) catch {
            continue;
        };
        if (resp.status >= 200 and resp.status < 300) return resp.body;
        if (resp.status >= 400 and resp.status < 500) {
            resp.deinit(allocator);
            return null;
        }
        resp.deinit(allocator);
    }
    std.log.warn("openlibrary: giving up on {s} after {d} attempts", .{ url, delays_ms.len });
    return null;
}

fn stripWorksPrefix(key: []const u8) []const u8 {
    const prefix = "/works/";
    if (std.mem.startsWith(u8, key, prefix)) return key[prefix.len..];
    return key;
}

fn extractFirstWorkKey(allocator: std.mem.Allocator, body: []const u8) !?[]const u8 {
    return extractWorkKeyAt(allocator, body, 0);
}

fn extractWorkKeyAt(allocator: std.mem.Allocator, body: []const u8, idx: usize) !?[]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const docs = parsed.value.object.get("docs") orelse return null;
    if (docs != .array or docs.array.items.len <= idx) return null;
    const doc = docs.array.items[idx];
    if (doc != .object) return null;
    const k = doc.object.get("key") orelse return null;
    if (k != .string) return null;
    return try allocator.dupe(u8, k.string);
}

/// Pick the best-matching doc index for a search response. Ranking
/// criteria (positive = better):
///   +1000  author surname appears in `author_name`
///   + 300  language array contains "eng"
///   + 100  has an ISBN-13 (mass-market edition is likely)
///   + (clamp 0..40)  edition_count / 5  (republish frequency)
///   - 500  title contains "graphic novel" / "abridged" / "screenplay" /
///          "adapted" / "audiobook" — clearly derivative editions
/// Returns null when `docs` is empty or unparseable so the caller
/// falls back to index 0.
fn chooseBestSearchDoc(
    allocator: std.mem.Allocator,
    body: []const u8,
    q: provider_iface.Query,
) !?usize {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const docs_v = parsed.value.object.get("docs") orelse return null;
    if (docs_v != .array or docs_v.array.items.len == 0) return null;
    const docs = docs_v.array.items;
    if (docs.len == 1) return 0;

    var best_idx: usize = 0;
    var best_score: i64 = std.math.minInt(i64);
    for (docs, 0..) |doc, i| {
        if (doc != .object) continue;
        const score = scoreDoc(doc.object, q);
        if (score > best_score) {
            best_score = score;
            best_idx = i;
        }
    }
    return best_idx;
}

fn scoreDoc(doc: std.json.ObjectMap, q: provider_iface.Query) i64 {
    var s: i64 = 0;

    if (q.title) |qt| {
        if (doc.get("title")) |t| {
            if (t == .string and qt.len > 0 and t.string.len > 0) {
                if (containsCi(t.string, qt)) {
                    const ratio = (qt.len * 100) / @max(qt.len, t.string.len);
                    s += @divFloor(500 * @as(i64, @intCast(ratio)), 100);
                }
            }
        }
    }

    if (q.author) |a| {
        const surname = firstWord(a);
        if (surname.len > 2) {
            if (doc.get("author_name")) |an| {
                if (an == .array) {
                    for (an.array.items) |x| {
                        if (x != .string) continue;
                        if (containsCi(x.string, surname)) {
                            s += 1000;
                            break;
                        }
                    }
                }
            }
        }
    }

    if (doc.get("language")) |lang| {
        if (lang == .array) {
            for (lang.array.items) |l| {
                if (l != .string) continue;
                if (std.mem.eql(u8, l.string, "eng")) {
                    s += 300;
                    break;
                }
            }
        }
    }

    if (doc.get("edition_count")) |ec| {
        if (ec == .integer) {
            const capped = @min(ec.integer, 200);
            s += @divFloor(capped, 5);
        }
    }

    if (doc.get("isbn")) |is| {
        if (is == .array) {
            for (is.array.items) |x| {
                if (x != .string) continue;
                if (x.string.len == 13) {
                    s += 100;
                    break;
                }
            }
        }
    }

    if (doc.get("title")) |t| {
        if (t == .string) {
            const bad = [_][]const u8{
                "graphic novel", "abridged",    "screenplay",  "adapted",
                "audiobook",     "study guide", "cliffsnotes", "sparknotes",
            };
            for (bad) |needle| {
                if (containsCi(t.string, needle)) {
                    s -= 500;
                    break;
                }
            }
        }
    }

    return s;
}

fn firstWord(s: []const u8) []const u8 {
    var end: usize = 0;
    while (end < s.len) : (end += 1) {
        const ch = s[end];
        if (ch == ',' or ch == ' ' or ch == ';') break;
    }
    return s[0..end];
}

fn containsCi(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var i: usize = 0;
    outer: while (i + needle.len <= haystack.len) : (i += 1) {
        for (needle, 0..) |c, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(c)) continue :outer;
        }
        return true;
    }
    return false;
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

/// Parse Open Library's search.json response, returning metadata for
/// the first matching doc. Kept as a thin wrapper around
/// `parseSearchPayloadAt` for callers that don't care about ranking
/// (e.g. ISBN-already-known paths, tests).
pub fn parseSearchPayload(
    allocator: std.mem.Allocator,
    body: []const u8,
    q: provider_iface.Query,
) !?meta.BookMetadata {
    const idx = (chooseBestSearchDoc(allocator, body, q) catch null) orelse 0;
    return parseSearchPayloadAt(allocator, body, idx);
}

/// M1: parse every candidate from a `search.json` response, ordered
/// best-first (winning doc at index 0). Each entry carries enough for
/// the alternate-match picker (display) plus a full BookMetadata for
/// when the user selects it. The `chosen_idx` of the source search is
/// rotated to index 0 so the UI can render "current pick" + "other N".
pub fn parseSearchCandidates(
    allocator: std.mem.Allocator,
    body: []const u8,
    q: provider_iface.Query,
    chosen_idx: usize,
    cap: usize,
) ![]Candidate {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return &.{};
    defer parsed.deinit();
    if (parsed.value != .object) return &.{};
    const docs_v = parsed.value.object.get("docs") orelse return &.{};
    if (docs_v != .array) return &.{};
    const docs = docs_v.array.items;
    if (docs.len == 0) return &.{};

    const N = @min(docs.len, cap);
    var list: std.ArrayList(Candidate) = .empty;
    try list.ensureTotalCapacity(allocator, N);

    var indices: std.ArrayList(usize) = .empty;
    defer indices.deinit(allocator);
    try indices.append(allocator, chosen_idx);
    for (docs, 0..) |_, i| {
        if (i == chosen_idx) continue;
        try indices.append(allocator, i);
        if (indices.items.len >= N) break;
    }

    for (indices.items) |i| {
        if (i >= docs.len) continue;
        const doc_v = docs[i];
        if (doc_v != .object) continue;
        const doc = doc_v.object;

        var c: Candidate = .{};
        c.score = scoreDoc(doc, q);
        if (doc.get("title")) |t| if (t == .string) {
            c.title = try allocator.dupe(u8, t.string);
        };
        if (doc.get("author_name")) |an| {
            if (an == .array and an.array.items.len > 0) {
                const first = an.array.items[0];
                if (first == .string) c.author = try allocator.dupe(u8, first.string);
            }
        }
        if (doc.get("key")) |k| if (k == .string) {
            c.work_key = try allocator.dupe(u8, k.string);
        };
        if (doc.get("first_publish_year")) |y| {
            if (y == .integer and y.integer >= 1000 and y.integer < 3000) {
                c.year = @intCast(y.integer);
            }
        }
        if (doc.get("isbn")) |is| {
            if (is == .array and is.array.items.len > 0) {
                for (is.array.items) |it| {
                    if (it != .string) continue;
                    if (it.string.len == 13) {
                        c.isbn = try allocator.dupe(u8, it.string);
                        break;
                    }
                }
                if (c.isbn == null) {
                    const f = is.array.items[0];
                    if (f == .string) c.isbn = try allocator.dupe(u8, f.string);
                }
            }
        }
        if (doc.get("cover_i")) |ci| if (ci == .integer) {
            c.cover_url = try std.fmt.allocPrint(
                allocator,
                "https://covers.openlibrary.org/b/id/{d}-M.jpg",
                .{ci.integer},
            );
        };

        c.metadata = (try parseSearchPayloadAt(allocator, body, i)) orelse meta.BookMetadata{};
        try list.append(allocator, c);
    }
    return list.toOwnedSlice(allocator);
}

pub fn parseSearchPayloadAt(
    allocator: std.mem.Allocator,
    body: []const u8,
    idx: usize,
) !?meta.BookMetadata {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return null;
    const docs_v = root.object.get("docs") orelse return null;
    if (docs_v != .array or docs_v.array.items.len <= idx) return null;
    const doc_v = docs_v.array.items[idx];
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

pub const DetailsResult = struct {
    work_key: ?[]const u8 = null,
    md: ?meta.BookMetadata = null,
};

/// Parse a `jscmd=details` response and pull out the work key plus
/// anything we don't already get from `jscmd=data`. The returned
/// metadata is partial — callers merge it with parseIsbnPayload's
/// result for the final picture.
pub fn parseDetailsPayload(
    allocator: std.mem.Allocator,
    isbn: []const u8,
    body: []const u8,
) !DetailsResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return .{};
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .work_key = null, .md = null };

    var key_buf: [128]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "ISBN:{s}", .{isbn}) catch
        return .{};
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

        if (ed.isbn == null and ed.publisher == null and ed.published_year == null) continue;

        try list.append(allocator, ed);
        if (list.items.len >= cap) break;
    }

    const slice = try list.toOwnedSlice(allocator);
    std.sort.block(Edition, slice, {}, editionLessThan);
    return slice;
}

fn editionLessThan(_: void, a: Edition, b: Edition) bool {
    const ay = a.published_year orelse 0;
    const by = b.published_year orelse 0;
    if (ay != by) return ay > by;
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
        for (slice) |c| if (!std.ascii.isDigit(c)) {
            all_digit = false;
            break;
        };
        if (all_digit) {
            const y = std.fmt.parseInt(u16, slice, 10) catch continue;
            if (y >= 1000 and y < 3000) return y;
        }
    }
    return null;
}

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

test "normalizeQueryTitle strips subtitle after colon" {
    const a = std.testing.allocator;
    const r = try normalizeQueryTitle(a, "A Little Hatred: Book One (The Age of Madness)");
    defer a.free(r);
    try std.testing.expectEqualStrings("A Little Hatred", r);
}

test "normalizeQueryTitle strips trailing parens" {
    const a = std.testing.allocator;
    const r = try normalizeQueryTitle(a, "Some Book (Series Name 1)");
    defer a.free(r);
    try std.testing.expectEqualStrings("Some Book", r);
}

test "normalizeQueryTitle strips chained trailing parens" {
    const a = std.testing.allocator;
    const r = try normalizeQueryTitle(a, "Title (Series 1) (Hardcover)");
    defer a.free(r);
    try std.testing.expectEqualStrings("Title", r);
}

test "normalizeQueryTitle leaves plain titles alone" {
    const a = std.testing.allocator;
    const r = try normalizeQueryTitle(a, "Hyperion");
    defer a.free(r);
    try std.testing.expectEqualStrings("Hyperion", r);
}

test "normalizeQueryTitle preserves leading-acronym colon" {
    const a = std.testing.allocator;
    const r = try normalizeQueryTitle(a, "F:Equation");
    defer a.free(r);
    try std.testing.expectEqualStrings("F:Equation", r);
}

test "normalizeQueryTitle collapses internal whitespace" {
    const a = std.testing.allocator;
    const r = try normalizeQueryTitle(a, "  A    Little   Hatred  ");
    defer a.free(r);
    try std.testing.expectEqualStrings("A Little Hatred", r);
}

const dummy_io_test: std.Io = undefined;

test "lookup ISBN: 200 → parses metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mock = http.MockClient.init(std.testing.allocator);
    defer mock.deinit();
    try mock.add(
        "https://openlibrary.org/api/books?bibkeys=ISBN:9780765365279&format=json&jscmd=data",
        200,
        \\{"ISBN:9780765365279":{"title":"The Way of Kings","publish_date":"2010","authors":[{"name":"Brandon Sanderson"}]}}
        ,
    );

    var ol = OpenLibrary{ .http_client = mock.client() };
    const md_opt = try ol.lookup(a, dummy_io_test, .{ .isbn = "9780765365279" });
    try std.testing.expect(md_opt != null);
    try std.testing.expectEqualStrings("The Way of Kings", md_opt.?.title.?);
    try std.testing.expectEqual(@as(usize, 1), mock.calls.items.len);
}

test "lookup ISBN: 404 → null without raising" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mock = http.MockClient.init(std.testing.allocator);
    defer mock.deinit();
    try mock.add(
        "https://openlibrary.org/api/books?bibkeys=ISBN:nothing&format=json&jscmd=data",
        404,
        "{}",
    );

    var ol = OpenLibrary{ .http_client = mock.client() };
    const md_opt = try ol.lookup(a, dummy_io_test, .{ .isbn = "nothing" });
    try std.testing.expect(md_opt == null);
}

test "lookup ISBN: HTTP error → null (graceful degradation)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mock = http.MockClient.init(std.testing.allocator);
    defer mock.deinit();

    var ol = OpenLibrary{ .http_client = mock.client() };
    const md_opt = try ol.lookup(a, dummy_io_test, .{ .isbn = "9780000000000" });
    try std.testing.expect(md_opt == null);
    try std.testing.expectEqual(@as(usize, 1), mock.calls.items.len);
}

test "lookup title: hits search endpoint with URL-encoded params" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mock = http.MockClient.init(std.testing.allocator);
    defer mock.deinit();
    try mock.add(
        "https://openlibrary.org/search.json?title=Hyperion&author=Simmons&limit=10",
        200,
        \\{"docs":[{"title":"Hyperion","author_name":["Dan Simmons"],"first_publish_year":1989,"edition_count":50}]}
        ,
    );

    var ol = OpenLibrary{ .http_client = mock.client() };
    const md_opt = try ol.lookup(a, dummy_io_test, .{ .title = "Hyperion", .author = "Simmons" });
    try std.testing.expect(md_opt != null);
    try std.testing.expectEqualStrings("Hyperion", md_opt.?.title.?);
    try std.testing.expectEqual(@as(u16, 1989), md_opt.?.published_year.?);
}

test "lookupRichDiag: search ladder records attempts when all 0 docs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mock = http.MockClient.init(std.testing.allocator);
    defer mock.deinit();
    try mock.add(
        "https://openlibrary.org/search.json?title=Foo%3A+Bar&author=Baz&limit=10",
        200,
        \\{"docs":[]}
        ,
    );
    try mock.add(
        "https://openlibrary.org/search.json?title=Foo&author=Baz&limit=10",
        200,
        \\{"docs":[]}
        ,
    );
    try mock.add(
        "https://openlibrary.org/search.json?title=Foo&author=&limit=10",
        200,
        \\{"docs":[]}
        ,
    );

    var ol = OpenLibrary{ .http_client = mock.client() };
    const diag = try ol.lookupRichDiag(a, dummy_io_test, .{ .title = "Foo: Bar", .author = "Baz" });
    try std.testing.expect(diag.result == null);
    try std.testing.expectEqual(@as(usize, 3), diag.attempts.len);
    try std.testing.expectEqual(@as(usize, 3), mock.calls.items.len);
}
