const std = @import("std");

// Build script for mediastacks.
//
// Wires up:
//   - vendored miniz (C source compiled in-tree)
//   - libmobi (system lib via Homebrew)
//   - libxml2 (system lib, ships with macOS SDK)
//   - sqlite3 (system lib)
//
// In Zig 0.16, C headers are translated through the build system
// (b.addTranslateC) rather than via @cImport in source files.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---- Discover system include / library paths ------------------------
    // Homebrew on Apple Silicon installs to /opt/homebrew. We probe a few
    // well-known prefixes so the same build.zig works on Linux too.
    const include_dirs = collectIncludeDirs(b);
    const library_dirs = collectLibraryDirs(b);

    // ---- Translate C headers (replaces @cImport) ------------------------
    // miniz is left out of the bulk translation because translate-c (Zig
    // 0.16.0) crashes on its zlib-compat header; we declare its tiny
    // surface manually in src/ffi/miniz.zig.
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/ffi/c_includes.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    for (include_dirs) |dir| translate_c.addIncludePath(.{ .cwd_relative = dir });

    const c_module = translate_c.createModule();

    // ---- libvaxis (TUI library) ---------------------------------------
    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    const vaxis_mod = vaxis_dep.module("vaxis");

    // ---- mediastacks library module ---------------------------------------
    const mediastacks_mod = b.addModule("mediastacks", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "c", .module = c_module },
            .{ .name = "vaxis", .module = vaxis_mod },
        },
    });

    // Compile vendored miniz directly into the library module.
    mediastacks_mod.addCSourceFile(.{
        .file = b.path("lib/miniz/miniz.c"),
        .flags = &.{ "-std=c99", "-Wno-unused-function" },
    });
    mediastacks_mod.addIncludePath(b.path("lib/miniz"));

    // Vendored SQLite amalgamation — compiled in-tree so there's no system
    // sqlite dependency on any platform (simplifies Nix/install and is a
    // prerequisite for Windows, which has no system sqlite3). Added before the
    // C helpers so its header wins the include search over any system copy.
    mediastacks_mod.addIncludePath(b.path("lib/sqlite"));
    mediastacks_mod.addCSourceFile(.{
        .file = b.path("lib/sqlite/sqlite3.c"),
        .flags = &.{ "-std=c99", "-w", "-DSQLITE_THREADSAFE=1" },
    });

    // Small C-side helpers for things translate-c can't express cleanly.
    mediastacks_mod.addCSourceFile(.{
        .file = b.path("lib/mediastacks_c/sqlite_helpers.c"),
        .flags = &.{"-std=c99"},
    });

    // Cover thumbnailer (stb_image + stb_image_resize2 + stb_image_write).
    // Compiled with `-fno-sanitize=undefined` because stb's JPEG writer
    // performs signed left-shifts on `int bitBuf` that Clang's UBSAN
    // flags — even though the wrapping behaviour is intentional. The
    // generated JPEG is correct; UBSAN is overly conservative here.
    mediastacks_mod.addCSourceFile(.{
        .file = b.path("lib/mediastacks_c/cover_resize.c"),
        .flags = &.{
            "-std=c11",
            "-fno-sanitize=undefined",
            "-Wno-unused-function",
            "-Wno-unused-but-set-variable",
            "-Wno-sign-compare",
            "-Wno-missing-field-initializers",
        },
    });

    // System libraries. sqlite is vendored above. libmobi + libxml2 back the
    // book/comic (biblio) formats, which are POSIX-only — skip them on Windows,
    // where the medias-only build comptime-excludes those code paths.
    const is_windows = target.result.os.tag == .windows;
    if (!is_windows) {
        for (library_dirs) |dir| mediastacks_mod.addLibraryPath(.{ .cwd_relative = dir });
        for (include_dirs) |dir| mediastacks_mod.addIncludePath(.{ .cwd_relative = dir });
        mediastacks_mod.linkSystemLibrary("mobi", .{});
        mediastacks_mod.linkSystemLibrary("xml2", .{});
    }

    // ---- Executable ----------------------------------------------------
    const exe = b.addExecutable(.{
        .name = "biblio",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mediastacks", .module = mediastacks_mod },
            },
        }),
    });
    // biblio needs libmobi + libxml2 (POSIX-only book/comic formats), so it is
    // not built on Windows — only `medias` targets Windows for now.
    if (!is_windows) {
        b.installArtifact(exe);

        // ---- `zig build run -- ARGS...` -------------------------------
        const run_step = b.step("run", "Run biblio");
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_cmd.addArgs(args);
        run_step.dependOn(&run_cmd.step);
    }

    // ---- Second executable: the media organizer -----------------------
    const medias_exe = b.addExecutable(.{
        .name = "medias",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/medias_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mediastacks", .module = mediastacks_mod },
            },
        }),
    });
    b.installArtifact(medias_exe);

    const medias_run_step = b.step("run-medias", "Run medias");
    const medias_run_cmd = b.addRunArtifact(medias_exe);
    medias_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| medias_run_cmd.addArgs(args);
    medias_run_step.dependOn(&medias_run_cmd.step);

    // ---- `zig build test` ---------------------------------------------
    const mod_tests = b.addTest(.{ .root_module = mediastacks_mod });
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const medias_tests = b.addTest(.{ .root_module = medias_exe.root_module });

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
    test_step.dependOn(&b.addRunArtifact(medias_tests).step);
}

// Probe well-known prefixes for system C headers.
fn collectIncludeDirs(b: *std.Build) []const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    const candidates = [_][]const u8{
        "/opt/homebrew/include", // Apple Silicon Homebrew
        "/opt/homebrew/opt/libmobi/include",
        "/opt/homebrew/opt/libxml2/include/libxml2",
        "/usr/local/include", // Intel Homebrew or hand-installed
        "/usr/local/opt/libmobi/include",
        "/usr/local/opt/libxml2/include/libxml2",
        "/usr/include", // Linux
        "/usr/include/libxml2",
        // macOS Command Line Tools SDK (libxml2)
        "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include",
        "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/libxml2",
    };
    for (candidates) |c| {
        if (dirExists(c)) list.append(b.allocator, c) catch @panic("OOM");
    }
    // Also honor the environment so non-Homebrew prefixes work (Nix, custom).
    appendEnvDirs(b, &list, "C_INCLUDE_PATH");
    appendEnvDirs(b, &list, "CPATH");
    return list.toOwnedSlice(b.allocator) catch @panic("OOM");
}

/// Append existing `:`-separated dirs from environment variable `name`.
fn appendEnvDirs(b: *std.Build, list: *std.ArrayList([]const u8), name: [*:0]const u8) void {
    const raw = std.c.getenv(name) orelse return;
    const val = std.mem.span(raw);
    var it = std.mem.tokenizeScalar(u8, val, ':');
    while (it.next()) |dir| {
        if (dirExists(dir)) list.append(b.allocator, b.dupe(dir)) catch @panic("OOM");
    }
}

fn collectLibraryDirs(b: *std.Build) []const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    const candidates = [_][]const u8{
        "/opt/homebrew/lib",
        "/opt/homebrew/opt/libmobi/lib",
        "/opt/homebrew/opt/libxml2/lib",
        "/usr/local/lib",
        "/usr/local/opt/libmobi/lib",
        "/usr/lib",
    };
    for (candidates) |c| {
        if (dirExists(c)) list.append(b.allocator, c) catch @panic("OOM");
    }
    appendEnvDirs(b, &list, "LIBRARY_PATH");
    return list.toOwnedSlice(b.allocator) catch @panic("OOM");
}

fn dirExists(path: []const u8) bool {
    // Use libc access() — works in 0.16 build scripts where std.fs / std.Io
    // are restructured. F_OK = 0 (existence test).
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return std.c.access(@ptrCast(&buf), 0) == 0;
}
