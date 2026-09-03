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

    // How hard the seeded differential fuzzer runs. The defaults are what
    // every `zig build test` pays for; a soak raises the count and walks the
    // seed, which is the only way to reach cases a single fixed seed never
    // generates. Build options rather than environment variables because a
    // test binary has no portable way to read the environment.
    const fuzz_opts = b.addOptions();
    fuzz_opts.addOption(
        usize,
        "cases",
        b.option(usize, "fuzz-cases", "Seeded differential fuzz cases per run (default 3000)") orelse 3000,
    );
    fuzz_opts.addOption(
        u64,
        "seed",
        b.option(u64, "fuzz-seed", "Seed for the seeded differential fuzzer") orelse 0x2026_08_31,
    );
    fuzz_opts.addOption(
        usize,
        "alloc_cases",
        b.option(usize, "fuzz-alloc-cases", "Allocation-failure fuzz cases per run (default 40)") orelse 40,
    );
    mod.addImport("fuzz_options", fuzz_opts.createModule());

    // Case-folding tables, generated from the `uucode` package rather than
    // written out here or fetched at run time. Only the fifteen hundred
    // codepoints that actually fold end up in the library, and because the
    // result is an ordinary Zig source file it is available to
    // `Regex.compileComptime` as well as at run time. `uucode` is therefore a
    // build-time dependency only; nothing links against it.
    const casefold_mod = blk: {
        // The Unicode data comes from `uucode`, but as the `CaseFolding.txt`
        // it vendors rather than through its generated tables: the fields that
        // distinguish a simple fold from a Turkic one -- which is the
        // distinction that decides whether `İ` matches `i` -- do not currently
        // build (`memset: unsupported non-byte-aligned type`, uucode 0.2.0).
        // Reading the file says exactly what is wanted, and says it in the
        // vocabulary of the Unicode standard rather than of a library.
        const uucode = b.dependency("uucode", .{});

        const gen = b.addExecutable(.{
            .name = "gen-casefold",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/gen_casefold.zig"),
                // Always built for the machine running the build: it is run
                // during the build, whatever `-Dtarget` was asked for.
                .target = b.graph.host,
                .optimize = .ReleaseSafe,
            }),
        });
        const run_gen = b.addRunArtifact(gen);
        run_gen.addFileArg(uucode.path("ucd/CaseFolding.txt"));
        break :blk b.createModule(.{
            .root_source_file = run_gen.addOutputFileArg("casefold.zig"),
        });
    };
    mod.addImport("casefold", casefold_mod);

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

    // Differential testing against PCRE2.
    //
    // The reference is built from source by PCRE2's own build.zig -- 10.48 is
    // the first release to ship one -- pinned in build.zig.zon, so
    // `zig build oracle` works the same on any machine with no system
    // library involved. That pin is what pins the reference *semantics*: the
    // weekly CI's first run reported a dozen disagreements that were all apt
    // shipping 10.42, whose POSIX class behavior differs from the version
    // the oracle is written against. The dependency is lazy and only fetched
    // when this wiring runs, which is every build; the two options below
    // override it with an external build, which is how version-drift
    // experiments like that diagnosis are run.
    const pcre2_include = b.option([]const u8, "pcre2-include", "Override: directory holding pcre2.h");
    const pcre2_lib = b.option([]const u8, "pcre2-lib", "Override: directory holding libpcre2-8");
    oracle: {
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
        oracle.root_module.link_libc = true;
        if (pcre2_include) |inc| {
            oracle.root_module.addIncludePath(.{ .cwd_relative = inc });
            if (pcre2_lib) |lib| oracle.root_module.addLibraryPath(.{ .cwd_relative = lib });
            oracle.root_module.linkSystemLibrary("pcre2-8", .{});
        } else if (b.lazyDependency("pcre2", .{
            .target = target,
            .optimize = std.builtin.OptimizeMode.ReleaseFast,
            .linkage = std.builtin.LinkMode.static,
        })) |pcre2| {
            // Upstream defaults: 8-bit code units, Unicode on, JIT off (so
            // its sljit dependency stays unfetched). Static, because the
            // oracle is a test tool that should carry its reference with it.
            oracle.root_module.linkLibrary(pcre2.artifact("pcre2-8"));
        } else {
            // Fetch pending; the build runner fetches and configures again.
            break :oracle;
        }

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
