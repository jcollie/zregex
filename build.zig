// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library module, importable as `@import("zregex")`.
    const mod = b.addModule("zregex", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Demo CLI.
    const exe = b.addExecutable(.{
        .name = "zregex",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zregex", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the demo CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // API documentation. Autodocs are emitted as a static site: index.html,
    // the viewer's wasm and javascript, and the sources it reads from.
    const docs_library = b.addLibrary(.{
        .name = "zregex",
        .root_module = mod,
    });

    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_library.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Build the API documentation into zig-out/docs");
    docs_step.dependOn(&install_docs.step);

    // The generated viewer fetches `sources.tar` and `main.wasm` at runtime,
    // which a browser refuses to do from a `file://` page, so reading the docs
    // locally means serving them. This is the same reason `zig std` runs a
    // server rather than just opening a file.
    const docs_port = b.option(u16, "docs-port", "Port for `zig build docs-serve` (default 8000)") orelse 8000;

    const docs_server = b.addExecutable(.{
        .name = "docs-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/docs_server.zig"),
            // Always built for the machine running the build, never for
            // whatever `-Dtarget` the library is being built for.
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const run_docs_server = b.addRunArtifact(docs_server);
    run_docs_server.step.dependOn(&install_docs.step);
    run_docs_server.addArg(b.getInstallPath(.prefix, "docs"));
    run_docs_server.addArg(b.fmt("{d}", .{docs_port}));
    // The server runs until interrupted, so its output has to reach the
    // terminal rather than being captured by the build runner.
    run_docs_server.stdio = .inherit;

    const docs_serve_step = b.step("docs-serve", "Serve the API documentation over HTTP");
    docs_serve_step.dependOn(&run_docs_server.step);

    // The server has tests of its own; without this they would never run.
    const docs_server_tests = b.addTest(.{ .root_module = docs_server.root_module });
    test_step.dependOn(&b.addRunArtifact(docs_server_tests).step);

    // Benchmark harness (always ReleaseFast); see bench/run.sh.
    const bench_exe = b.addExecutable(.{
        .name = "bench-zregex",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench_zregex.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "zregex", .module = mod },
            },
        }),
    });
    const bench_step = b.step("bench", "Build the benchmark harness");
    bench_step.dependOn(&b.addInstallArtifact(bench_exe, .{}).step);
}
