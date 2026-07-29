const std = @import("std");

// Build script for booktool.
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

    // ---- booktool library module ---------------------------------------
    const stacks_mod = b.addModule("stacks", .{
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
    stacks_mod.addCSourceFile(.{
        .file = b.path("lib/miniz/miniz.c"),
        .flags = &.{ "-std=c99", "-Wno-unused-function" },
    });
    stacks_mod.addIncludePath(b.path("lib/miniz"));

    // Small C-side helpers for things translate-c can't express cleanly.
    stacks_mod.addCSourceFile(.{
        .file = b.path("lib/booktool_c/sqlite_helpers.c"),
        .flags = &.{"-std=c99"},
    });

    // Cover thumbnailer (stb_image + stb_image_resize2 + stb_image_write).
    // Compiled with `-fno-sanitize=undefined` because stb's JPEG writer
    // performs signed left-shifts on `int bitBuf` that Clang's UBSAN
    // flags — even though the wrapping behaviour is intentional. The
    // generated JPEG is correct; UBSAN is overly conservative here.
    stacks_mod.addCSourceFile(.{
        .file = b.path("lib/booktool_c/cover_resize.c"),
        .flags = &.{
            "-std=c11",
            "-fno-sanitize=undefined",
            "-Wno-unused-function",
            "-Wno-unused-but-set-variable",
            "-Wno-sign-compare",
            "-Wno-missing-field-initializers",
        },
    });

    // Link system libraries.
    for (library_dirs) |dir| stacks_mod.addLibraryPath(.{ .cwd_relative = dir });
    for (include_dirs) |dir| stacks_mod.addIncludePath(.{ .cwd_relative = dir });
    stacks_mod.linkSystemLibrary("mobi", .{});
    stacks_mod.linkSystemLibrary("xml2", .{});
    stacks_mod.linkSystemLibrary("sqlite3", .{});

    // ---- Executable ----------------------------------------------------
    const exe = b.addExecutable(.{
        .name = "biblio",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "stacks", .module = stacks_mod },
            },
        }),
    });
    b.installArtifact(exe);

    // ---- `zig build run -- ARGS...` -----------------------------------
    const run_step = b.step("run", "Run biblio");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // ---- Second executable: the media organizer -----------------------
    const shelve_exe = b.addExecutable(.{
        .name = "shelve",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/shelve_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "stacks", .module = stacks_mod },
            },
        }),
    });
    b.installArtifact(shelve_exe);

    const shelve_run_step = b.step("run-shelve", "Run shelve");
    const shelve_run_cmd = b.addRunArtifact(shelve_exe);
    shelve_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| shelve_run_cmd.addArgs(args);
    shelve_run_step.dependOn(&shelve_run_cmd.step);

    // ---- `zig build test` ---------------------------------------------
    const mod_tests = b.addTest(.{ .root_module = stacks_mod });
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const shelve_tests = b.addTest(.{ .root_module = shelve_exe.root_module });

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
    test_step.dependOn(&b.addRunArtifact(shelve_tests).step);
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
    return list.toOwnedSlice(b.allocator) catch @panic("OOM");
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
