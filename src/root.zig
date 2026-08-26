//! Public library surface for booktool.
//!
//! The CLI in `cli.zig` is a thin dispatcher over these modules; the future
//! TUI and Web UI will call the same APIs.

const std = @import("std");

pub const cli = @import("cli.zig");
pub const shelve_cli = @import("shelve_cli.zig");

pub const kind = @import("core/kind.zig");
pub const classify = @import("core/classify.zig");
pub const tv = @import("kinds/tv.zig");
pub const movie = @import("kinds/movie.zig");
pub const music = @import("kinds/music.zig");
pub const music_tags = @import("kinds/music_tags.zig");
pub const mediascore = @import("core/mediascore.zig");
pub const probe = @import("core/probe.zig");
pub const enrich = @import("core/enrich.zig");
pub const drm = @import("core/drm.zig");
pub const plan = @import("core/plan.zig");
pub const config = @import("core/config.zig");
pub const group = @import("core/group.zig");
pub const extras = @import("core/extras.zig");
pub const nfo = @import("core/nfo.zig");
pub const textnorm = @import("core/textnorm.zig");
pub const audiobook = @import("kinds/audiobook.zig");
pub const comic = @import("kinds/comic.zig");
pub const naming = @import("core/naming.zig");
pub const journal = @import("core/journal.zig");
pub const apply = @import("core/apply.zig");
pub const organize_cmd = @import("commands/organize.zig");
pub const undo_cmd = @import("commands/undo.zig");
pub const index_cmd = @import("commands/index.zig");
pub const metadata = @import("core/metadata.zig");
pub const catalog = @import("core/catalog.zig");
pub const mediacatalog = @import("core/mediacatalog.zig");
pub const indexer = @import("core/indexer.zig");
pub const dedup = @import("core/dedup.zig");
pub const quality = @import("core/quality.zig");
pub const glob = @import("core/glob.zig");
pub const template = @import("core/template.zig");
pub const score = @import("core/score.zig");
pub const standardize = @import("core/standardize.zig");
pub const jobs = @import("core/jobs.zig");
pub const job_runner = @import("core/job_runner.zig");

pub const format = @import("formats/format.zig");
pub const epub = @import("formats/epub.zig");
pub const epub_chapters = @import("formats/epub_chapters.zig");
pub const mobi = @import("formats/mobi.zig");
pub const pdf = @import("formats/pdf.zig");
pub const cbz = @import("formats/cbz.zig");
pub const cbr = @import("formats/cbr.zig");
pub const cb7 = @import("formats/cb7.zig");
pub const cbt = @import("formats/cbt.zig");
pub const comic_archive = @import("formats/comic_archive.zig");
pub const format_handler = @import("formats/handler.zig");
pub const format_registry = @import("formats/registry.zig");

pub const provider = @import("providers/provider.zig");
pub const openlibrary = @import("providers/openlibrary.zig");
pub const musicbrainz = @import("providers/musicbrainz.zig");
pub const tmdb = @import("providers/tmdb.zig");

pub const convert = @import("convert/convert.zig");

pub const hash = @import("util/hash.zig");
pub const isbn = @import("util/isbn.zig");
pub const fuzzy = @import("util/fuzzy.zig");
pub const http = @import("util/http.zig");
pub const httpcache = @import("util/httpcache.zig");
pub const shutdown = @import("util/shutdown.zig");

pub const web_api = @import("web/api.zig");
pub const review = @import("web/review.zig");
pub const web_app = @import("web/app.zig");
pub const media_enrich = @import("web/media_enrich.zig");
pub const media_enrich_job = @import("web/media_enrich_job.zig");

test {
    std.testing.refAllDecls(@This());
    _ = kind;
    _ = classify;
    _ = tv;
    _ = movie;
    _ = music;
    _ = mediascore;
    _ = probe;
    _ = enrich;
    _ = drm;
    _ = plan;
    _ = config;
    _ = group;
    _ = naming;
    _ = journal;
    _ = apply;
    _ = organize_cmd;
    _ = undo_cmd;
    _ = metadata;
    _ = catalog;
    _ = dedup;
    _ = score;
    _ = template;
    _ = jobs;
    _ = job_runner;
    _ = quality;
    _ = glob;
    _ = format;
    _ = epub;
    _ = epub_chapters;
    _ = mobi;
    _ = pdf;
    _ = cbz;
    _ = format_handler;
    _ = format_registry;
    _ = openlibrary;
    _ = isbn;
    _ = fuzzy;
    _ = hash;
    _ = convert;
    _ = web_api;
    _ = review;
    _ = @import("tui/reflow.zig");
}
