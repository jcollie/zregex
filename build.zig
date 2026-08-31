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

    // Random pattern generation, shared by the in-tree fuzzer and the
    // external-oracle tool, so it is a module rather than a plain file.
    const gen_mod = b.addModule("pattern_gen", .{
        .root_source_file = b.path("src/pattern_gen.zig"),
        .target = target,
    });
    mod.addImport("pattern_gen", gen_mod);

    // On Windows the JIT maps executable memory through the Win32 API.
    // Lazy, so builds for other targets never fetch the bindings.
    if (target.result.os.tag == .windows) {
        if (b.lazyDependency("zigwin32", .{})) |win32| {
            mod.addImport("win32", win32.module("win32"));
        }
    }

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

    // Compiles everything for the chosen target without running any of it,
    // which is how cross-target coverage is checked. It goes through the
    // build system rather than `zig test -target ...` so that per-target
    // module wiring — the Win32 bindings, for one — is in place.
    const check_step = b.step("check", "Compile everything for the target without running it");
    check_step.dependOn(&mod_tests.step);
    check_step.dependOn(&exe_tests.step);
    check_step.dependOn(&exe.step);

    // Differential testing against PCRE2. Needs that library to link, so it
    // is opt-in rather than part of `zig build test`.
    const pcre2_include = b.option([]const u8, "pcre2-include", "Directory holding pcre2.h");
    const pcre2_lib = b.option([]const u8, "pcre2-lib", "Directory holding libpcre2-8");
    if (pcre2_include) |inc| {
        const oracle = b.addExecutable(.{
            .name = "oracle",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/oracle.zig"),
                .target = target,
                .optimize = .ReleaseFast,
                .imports = &.{
                    .{ .name = "zregex", .module = mod },
                    .{ .name = "pattern_gen", .module = gen_mod },
                },
            }),
        });
        oracle.root_module.addIncludePath(.{ .cwd_relative = inc });
        if (pcre2_lib) |lib| oracle.root_module.addLibraryPath(.{ .cwd_relative = lib });
        oracle.root_module.linkSystemLibrary("pcre2-8", .{});
        oracle.root_module.link_libc = true;

        const run_oracle = b.addRunArtifact(oracle);
        run_oracle.stdio = .inherit;
        if (b.args) |args| run_oracle.addArgs(args);
        const oracle_step = b.step("oracle", "Differential-test against PCRE2");
        oracle_step.dependOn(&run_oracle.step);
    }

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

    // Runs it too, which saves callers from knowing the executable suffix.
    // `zig build bench-run -- --builtin` needs no corpus file.
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.stdio = .inherit;
    if (b.args) |args| run_bench.addArgs(args);
    const bench_run_step = b.step("bench-run", "Build and run the benchmark harness");
    bench_run_step.dependOn(&run_bench.step);
}
