const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const CrossTarget = std.zig.CrossTarget;
const Mode = std.builtin.Mode;

const config = @import("./src/config.zig");

// TigerBeetle binary requires certain CPU feature and supports a closed set of CPUs. Here, we
// specify exactly which features the binary needs.
fn resolve_target(b: *std.Build, target_requested: ?[]const u8) !std.Build.ResolvedTarget {
    const target_host = @tagName(builtin.target.cpu.arch) ++ "-" ++ @tagName(builtin.target.os.tag);
    const target = target_requested orelse target_host;
    const triples = .{
        "aarch64-linux",
        "aarch64-macos",
        "x86_64-linux",
        "x86_64-macos",
        "x86_64-windows",
    };
    const cpus = .{
        "baseline+aes+neon",
        "baseline+aes+neon",
        "x86_64_v3+aes",
        "x86_64_v3+aes",
        "x86_64_v3+aes",
    };

    const arch_os, const cpu = inline for (triples, cpus) |triple, cpu| {
        if (std.mem.eql(u8, target, triple)) break .{ triple, cpu };
    } else {
        std.log.err("unsupported target: '{s}'", .{target});
        return error.UnsupportedTarget;
    };
    const query = try CrossTarget.parse(.{
        .arch_os_abi = arch_os,
        .cpu_features = cpu,
    });
    return b.resolveTargetQuery(query);
}

pub fn build(b: *std.Build) !void {
    // A compile error stack trace of 10 is arbitrary in size but helps with debugging.
    b.reference_trace = 10;

    // Top-level steps you can invoke on the command line.
    const build_steps = .{
        .aof = b.step("aof", "Run TigerBeetle AOF Utility"),
        .check = b.step("check", "Check if TigerBeetle compiles"),
        .clients_c = b.step("clients:c", "Build C client library"),
        .clients_c_sample = b.step("clients:c:sample", "Build C client sample"),
        .clients_dotnet = b.step("clients:dotnet", "Build dotnet client shared library"),
        .clients_go = b.step("clients:go", "Build Go client shared library"),
        .clients_java = b.step("clients:java", "Build Java client shared library"),
        .clients_node = b.step("clients:node", "Build Node client shared library"),
        .fuzz = b.step("fuzz", "Run non-VOPR fuzzers"),
        .fuzz_build = b.step("fuzz:build", "Build non-VOPR fuzzers"),
        .run = b.step("run", "Run TigerBeetle"),
        .scripts = b.step("scripts", "Free form automation scripts"),
        .@"test" = b.step("test", "Run all tests"),
        .test_fmt = b.step("test:fmt", "Check formatting"),
        .test_integration = b.step("test:integration", "Run integration tests"),
        .test_unit = b.step("test:unit", "Run unit tests"),
        .test_unit_build = b.step("test:unit:build", "Build unit tests"),
        .test_jni = b.step("test:jni", "Run Java JNI tests"),
        .vopr = b.step("vopr", "Run the VOPR"),
        .vopr_build = b.step("vopr:build", "Build the VOPR"),
    };

    // Build options passed with `-D` flags.
    const build_options = .{
        .target = b.option([]const u8, "target", "The CPU architecture and OS to build for"),
        .config = b.option(config.ConfigBase, "config", "Base configuration.") orelse .default,
        .config_aof_record = b.option(
            bool,
            "config-aof-record",
            "Enable AOF Recording.",
        ) orelse false,
        .config_aof_recovery = b.option(
            bool,
            "config-aof-recovery",
            "Enable AOF Recovery mode.",
        ) orelse false,
        .config_log_level = b.option(std.log.Level, "config-log-level", "Log level.") orelse .info,
        .config_release = b.option([]const u8, "config-release", "Release triple."),
        .config_release_client_min = b.option(
            []const u8,
            "config-release-client-min",
            "Minimum client release triple.",
        ),
        // We run extra checks in "CI-mode" build.
        .ci = b.graph.env_map.get("CI") != null,
        .emit_llvm_ir = b.option(bool, "emit-llvm-ir", "Emit LLVM IR (.ll file)") orelse false,
        // The "tigerbeetle version" command includes the build-time commit hash.
        .git_commit = b.option(
            []const u8,
            "git-commit",
            "The git commit revision of the source code.",
        ) orelse std.mem.trimRight(u8, b.run(&.{ "git", "rev-parse", "--verify", "HEAD" }), "\n"),
        .hash_log_mode = b.option(
            config.HashLogMode,
            "hash-log-mode",
            "Log hashes (used for debugging non-deterministic executions).",
        ) orelse .none,
        .vopr_state_machine = b.option(
            enum { testing, accounting },
            "vopr-state-machine",
            "State machine.",
        ) orelse .accounting,
        .vopr_log = b.option(
            enum { full, short },
            "vopr-log",
            "Log only state transitions (short) or everything (full).",
        ) orelse .short,
        .tracer_backend = b.option(
            config.TracerBackend,
            "tracer-backend",
            "Which backend to use for tracing.",
        ) orelse .none,
    };
    const target = try resolve_target(b, build_options.target);
    const mode = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const vsr_options = b.addOptions();
    assert(build_options.git_commit.len == 40);
    vsr_options.addOption(?[40]u8, "git_commit", build_options.git_commit[0..40].*);
    vsr_options.addOption(?[]const u8, "release", build_options.config_release);
    vsr_options.addOption(
        ?[]const u8,
        "release_client_min",
        build_options.config_release_client_min,
    );
    vsr_options.addOption(config.ConfigBase, "config_base", build_options.config);
    vsr_options.addOption(std.log.Level, "config_log_level", build_options.config_log_level);
    vsr_options.addOption(config.TracerBackend, "tracer_backend", build_options.tracer_backend);
    vsr_options.addOption(bool, "config_aof_record", build_options.config_aof_record);
    vsr_options.addOption(bool, "config_aof_recovery", build_options.config_aof_recovery);
    vsr_options.addOption(config.HashLogMode, "hash_log_mode", build_options.hash_log_mode);

    const vsr_module: *std.Build.Module = vsr: {
        const module = b.addModule("vsr", .{
            .root_source_file = b.path("src/vsr.zig"),
        });
        module.addOptions("vsr_options", vsr_options);

        switch (build_options.tracer_backend) {
            .none => {},
            .tracy => {
                // Code here is based on
                // https://github.com/ziglang/zig/blob/a660df4900520c505a0865707552dcc777f4b791/build.zig#L382

                // On mingw, we need to opt into windows 7+ to get some features required by tracy.
                const tracy_c_flags: []const []const u8 = if (target.result.isMinGW())
                    &[_][]const u8{
                        "-DTRACY_ENABLE=1",
                        "-DTRACY_FIBERS=1",
                        "-fno-sanitize=undefined",
                        "-D_WIN32_WINNT=0x601",
                    }
                else
                    &[_][]const u8{
                        "-DTRACY_ENABLE=1",
                        "-DTRACY_FIBERS=1",
                        "-fno-sanitize=undefined",
                    };

                const tracy = b.addSystemCommand(&.{
                    "git",
                    "clone",
                    "--branch=v0.9.1",
                    "https://github.com/wolfpld/tracy.git",
                }).addOutputDirectoryArg("tracy");

                module.addCSourceFile(.{
                    .file = tracy.path(b, "./public/TracyClient.cpp"),
                    .flags = tracy_c_flags,
                });
                module.addIncludePath(tracy.path(b, "./public/tracy"));
                module.link_libc = true;
                module.link_libcpp = true;

                if (target.result.os.tag == .windows) {
                    module.linkSystemLibrary("dbghelp", .{});
                    module.linkSystemLibrary("ws2_32", .{});
                }
            },
        }
        break :vsr module;
    };

    { // zig build check

        // Run a tigerbeetle build without running codegen and waiting for llvm
        // see <https://github.com/ziglang/zig/commit/5c0181841081170a118d8e50af2a09f5006f59e1>
        // how it's supposed to work.
        // In short, codegen only runs if zig build sees a dependency on the binary output of
        // the step. So we duplicate the build definition so that it doesn't get polluted by
        // b.installArtifact.
        // TODO(zig): https://github.com/ziglang/zig/issues/18877
        const tigerbeetle = b.addExecutable(.{
            .name = "tigerbeetle",
            .root_source_file = b.path("src/tigerbeetle/main.zig"),
            .target = target,
            .optimize = mode,
        });
        tigerbeetle.root_module.addImport("vsr", vsr_module);
        build_steps.check.dependOn(&tigerbeetle.step);
    }

    { // zig build
        const tigerbeetle = b.addExecutable(.{
            .name = "tigerbeetle",
            .root_source_file = b.path("src/tigerbeetle/main.zig"),
            .target = target,
            .optimize = mode,
        });
        tigerbeetle.root_module.addImport("vsr", vsr_module);
        tigerbeetle.root_module.addOptions("vsr_options", vsr_options);
        if (mode == .ReleaseSafe) {
            tigerbeetle.root_module.strip = build_options.tracer_backend == .none;
        }
        // Ensure that we get stack traces even in release builds.
        tigerbeetle.root_module.omit_frame_pointer = false;
        if (build_options.emit_llvm_ir) {
            _ = tigerbeetle.getEmittedLlvmIr();
        }

        b.installArtifact(tigerbeetle);
        // "zig build install" moves the server executable to the root folder:
        b.getInstallStep().dependOn(&CopyFile.create(
            b,
            tigerbeetle.getEmittedBin(),
            tigerbeetle.out_filename,
            .{},
        ).step);

        const run_cmd = b.addRunArtifact(tigerbeetle);
        if (b.args) |args| run_cmd.addArgs(args);
        build_steps.run.dependOn(&run_cmd.step);
    }

    const tb_client_header = blk: {
        const tb_client_header_generator = b.addExecutable(.{
            .name = "tb_client_header",
            .root_source_file = b.path("src/clients/c/tb_client_header.zig"),
            .target = target,
        });
        tb_client_header_generator.root_module.addImport("vsr", vsr_module);
        tb_client_header_generator.root_module.addOptions("vsr_options", vsr_options);
        break :blk Generated.file(b, .{
            .generator = tb_client_header_generator,
            .path = "./src/clients/c/tb_client.h",
        });
    };

    { // zig build aof
        const aof = b.addExecutable(.{
            .name = "aof",
            .root_source_file = b.path("src/aof.zig"),
            .target = target,
            .optimize = mode,
        });
        aof.root_module.addOptions("vsr_options", vsr_options);
        const run_cmd = b.addRunArtifact(aof);
        if (b.args) |args| run_cmd.addArgs(args);
        build_steps.aof.dependOn(&run_cmd.step);
    }

    { // zig build test -- "test filter"
        const unit_tests = b.addTest(.{
            .root_source_file = b.path("src/unit_tests.zig"),
            .target = target,
            .optimize = mode,
            .filters = b.args orelse &.{},
        });
        unit_tests.root_module.addOptions("vsr_options", vsr_options);
        // for src/clients/c/tb_client_header_test.zig to use cImport on tb_client.h
        unit_tests.linkLibC();
        unit_tests.addIncludePath(tb_client_header.path.dirname());

        build_steps.test_unit_build.dependOn(&b.addInstallArtifact(unit_tests, .{}).step);

        const run_unit_tests = b.addRunArtifact(unit_tests);
        run_unit_tests.setEnvironmentVariable("ZIG_EXE", b.graph.zig_exe);
        if (b.args != null) { // Don't cache test results if running a specific test.
            run_unit_tests.has_side_effects = true;
        }
        build_steps.test_unit.dependOn(&run_unit_tests.step);

        const integration_tests = b.addTest(.{
            .root_source_file = b.path("src/integration_tests.zig"),
            .target = target,
            .optimize = mode,
            .filters = b.args orelse &.{},
        });
        const run_integration_tests = b.addRunArtifact(integration_tests);
        if (b.args != null) { // Don't cache test results if running a specific test.
            run_integration_tests.has_side_effects = true;
        }
        // Ensure integration test have tigerbeetle binary.
        run_integration_tests.step.dependOn(b.getInstallStep());
        build_steps.test_integration.dependOn(&run_integration_tests.step);

        const run_fmt = b.addFmt(.{ .paths = &.{"."}, .check = true });
        build_steps.test_fmt.dependOn(&run_fmt.step);

        build_steps.@"test".dependOn(&run_unit_tests.step);
        if (b.args == null) {
            build_steps.@"test".dependOn(&run_integration_tests.step);
            build_steps.@"test".dependOn(&run_fmt.step);
        }
    }

    { // zig build test:jni

        // JNI test require JVM to be present, and are _not_ run as a part of `zig build test`.
        // We need libjvm.so both at build time and at a runtime, so use `FailStep` when that is not
        // available.
        if (b.graph.env_map.get("JAVA_HOME")) |java_home| {
            const libjvm_path = b.pathJoin(&.{
                java_home,
                if (builtin.os.tag == .windows) "/lib" else "/lib/server",
            });

            const tests = b.addTest(.{
                .root_source_file = b.path("src/clients/java/src/jni_tests.zig"),
                .target = target,
                // TODO(zig): The function `JNI_CreateJavaVM` tries to detect
                // the stack size and causes a SEGV that is handled by Zig's panic handler.
                // https://bugzilla.redhat.com/show_bug.cgi?id=1572811#c7
                //
                // The workaround is run the tests in "ReleaseFast" mode.
                .optimize = if (builtin.os.tag == .windows) .ReleaseFast else mode,
            });
            tests.linkLibC();

            tests.linkSystemLibrary("jvm");
            tests.addLibraryPath(.{ .cwd_relative = libjvm_path });
            if (builtin.os.tag == .linux) {
                // On Linux, detects the abi by calling `ldd` to check if
                // the libjvm.so is linked against libc or musl.
                // It's reasonable to assume that ldd will be present.
                var exit_code: u8 = undefined;
                const stderr_behavior = .Ignore;
                const ldd_result = try b.runAllowFail(
                    &.{ "ldd", b.pathJoin(&.{ libjvm_path, "libjvm.so" }) },
                    &exit_code,
                    stderr_behavior,
                );

                if (std.mem.indexOf(u8, ldd_result, "musl") != null) {
                    tests.root_module.resolved_target.?.query.abi = .musl;
                    tests.root_module.resolved_target.?.result.abi = .musl;
                } else if (std.mem.indexOf(u8, ldd_result, "libc") != null) {
                    tests.root_module.resolved_target.?.query.abi = .gnu;
                    tests.root_module.resolved_target.?.result.abi = .gnu;
                } else {
                    std.log.err("{s}", .{ldd_result});
                    return error.JavaAbiUnrecognized;
                }
            }

            switch (builtin.os.tag) {
                .windows => set_windows_dll(b.allocator, java_home),
                .macos => try b.graph.env_map.put("DYLD_LIBRARY_PATH", libjvm_path),
                .linux => try b.graph.env_map.put("LD_LIBRARY_PATH", libjvm_path),
                else => unreachable,
            }

            build_steps.test_jni.dependOn(&b.addRunArtifact(tests).step);
        } else {
            build_steps.test_jni.dependOn(&FailStep.add(
                b,
                "can't build jni tests tests, JAVA_HOME is not set",
            ).step);
        }
    }

    { // zig build vopr -- 42
        const vopr_options = b.addOptions();

        // When running without a SEED, default to release.
        const vopr_mode = if (b.args == null) .ReleaseSafe else mode;
        vopr_options.addOption(
            @TypeOf(build_options.vopr_state_machine),
            "state_machine",
            build_options.vopr_state_machine,
        );
        vopr_options.addOption(
            @TypeOf(build_options.vopr_log),
            "log",
            build_options.vopr_log,
        );

        const vopr = b.addExecutable(.{
            .name = "vopr",
            .root_source_file = b.path("src/vopr.zig"),
            .target = target,
            .optimize = vopr_mode,
        });
        vopr.root_module.addOptions("vsr_options", vsr_options);
        vopr.root_module.addOptions("vsr_vopr_options", vopr_options);
        // Ensure that we get stack traces even in release builds.
        vopr.root_module.omit_frame_pointer = false;
        build_steps.vopr_build.dependOn(&b.addInstallArtifact(vopr, .{}).step);

        const run_cmd = b.addRunArtifact(vopr);
        if (b.args) |args| run_cmd.addArgs(args);
        build_steps.vopr.dependOn(&run_cmd.step);
    }

    { // zig build fuzz -- --events-max=100 lsm_tree 123
        const fuzz_exe = b.addExecutable(.{
            .name = "fuzz",
            .root_source_file = b.path("src/fuzz_tests.zig"),
            .target = target,
            .optimize = mode,
        });
        fuzz_exe.root_module.addOptions("vsr_options", vsr_options);
        fuzz_exe.root_module.omit_frame_pointer = false;
        build_steps.fuzz_build.dependOn(&b.addInstallArtifact(fuzz_exe, .{}).step);

        const fuzz_run = b.addRunArtifact(fuzz_exe);
        if (b.args) |args| fuzz_run.addArgs(args);
        build_steps.fuzz.dependOn(&fuzz_run.step);
    }

    { // zig build scripts -- ci --language=java
        const scripts = b.addExecutable(.{
            .name = "scripts",
            .root_source_file = b.path("src/scripts.zig"),
            .target = target,
            .optimize = mode,
        });
        scripts.root_module.addOptions("vsr_options", vsr_options);
        const scripts_run = b.addRunArtifact(scripts);
        scripts_run.setEnvironmentVariable("ZIG_EXE", b.graph.zig_exe);
        if (b.args) |args| scripts_run.addArgs(args);
        build_steps.scripts.dependOn(&scripts_run.step);
    }

    { // zig build client:$lang
        go_client(b, build_steps.clients_go, mode, vsr_module, vsr_options, tb_client_header.path);
        java_client(b, build_steps.clients_java, mode, vsr_module, vsr_options);
        dotnet_client(b, build_steps.clients_dotnet, mode, vsr_module, vsr_options);
        node_client(b, build_steps.clients_node, mode, vsr_module, vsr_options);
        c_client(b, build_steps.clients_c, mode, vsr_options, tb_client_header);
    }

    { // zig build client:c:sample
        const static_lib = b.addStaticLibrary(.{
            .name = "tb_client",
            .root_source_file = b.path("src/tb_client_exports.zig"),
            .target = target,
            .optimize = mode,
        });
        static_lib.linkLibC();
        static_lib.pie = true;
        static_lib.bundle_compiler_rt = true;
        static_lib.root_module.addOptions("vsr_options", vsr_options);
        build_steps.clients_c_sample.dependOn(&static_lib.step);

        const sample = b.addExecutable(.{
            .name = "c_sample",
            .target = target,
            .optimize = mode,
        });
        sample.addCSourceFile(.{
            .file = b.path("src/clients/c/samples/main.c"),
        });
        sample.linkLibrary(static_lib);
        sample.linkLibC();

        if (target.result.os.tag == .windows) {
            static_lib.linkSystemLibrary("ws2_32");
            static_lib.linkSystemLibrary("advapi32");

            // TODO: Illegal instruction on Windows:
            sample.root_module.sanitize_c = false;
        }

        const install_step = b.addInstallArtifact(sample, .{});
        build_steps.clients_c_sample.dependOn(&install_step.step);
    }
}

// Zig cross-targets, Dotnet RID (Runtime Identifier), CPU features.
const platforms = .{
    .{ "x86_64-linux-gnu.2.27", "linux-x64", "x86_64_v3+aes" },
    .{ "x86_64-linux-musl", "linux-musl-x64", "x86_64_v3+aes" },
    .{ "x86_64-macos", "osx-x64", "x86_64_v3+aes" },
    .{ "aarch64-linux-gnu.2.27", "linux-arm64", "baseline+aes+neon" },
    .{ "aarch64-linux-musl", "linux-musl-arm64", "baseline+aes+neon" },
    .{ "aarch64-macos", "osx-arm64", "baseline+aes+neon" },
    .{ "x86_64-windows", "win-x64", "x86_64_v3+aes" },
};

fn strip_glibc_version(triple: []const u8) []const u8 {
    if (std.mem.endsWith(u8, triple, "gnu.2.27")) {
        return triple[0 .. triple.len - ".2.27".len];
    }
    assert(std.mem.indexOf(u8, triple, "gnu") == null);
    return triple;
}

fn go_client(
    b: *std.Build,
    build_step: *std.Build.Step,
    mode: Mode,
    vsr_module: *std.Build.Module,
    vsr_options: *std.Build.Step.Options,
    tb_client_header: std.Build.LazyPath,
) void {
    // Updates the generated header file:
    const tb_client_header_copy = Generated.file_copy(b, .{
        .from = tb_client_header,
        .path = "./src/clients/go/pkg/native/tb_client.h",
    });

    const go_bindings_generator = b.addExecutable(.{
        .name = "go_bindings",
        .root_source_file = b.path("src/clients/go/go_bindings.zig"),
        .target = b.graph.host,
    });
    go_bindings_generator.root_module.addImport("vsr", vsr_module);
    go_bindings_generator.root_module.addOptions("vsr_options", vsr_options);
    go_bindings_generator.step.dependOn(&tb_client_header_copy.step);
    const bindings = Generated.file(b, .{
        .generator = go_bindings_generator,
        .path = "./src/clients/go/pkg/types/bindings.go",
    });

    inline for (platforms) |platform| {
        // We don't need the linux-gnu builds.
        if (comptime std.mem.indexOf(u8, platform[0], "linux-gnu") != null) continue;

        const name = if (comptime std.mem.eql(u8, platform[0], "x86_64-linux-musl"))
            "x86_64-linux"
        else if (comptime std.mem.eql(u8, platform[0], "aarch64-linux-musl"))
            "aarch64-linux"
        else
            platform[0];

        const cross_target = CrossTarget.parse(.{
            .arch_os_abi = name,
            .cpu_features = platform[2],
        }) catch unreachable;
        const resolved_target = b.resolveTargetQuery(cross_target);

        const lib = b.addStaticLibrary(.{
            .name = "tb_client",
            .root_source_file = b.path("src/tb_client_exports.zig"),
            .target = resolved_target,
            .optimize = mode,
        });
        lib.linkLibC();
        lib.pie = true;
        lib.bundle_compiler_rt = true;
        lib.root_module.stack_protector = false;
        lib.root_module.addOptions("vsr_options", vsr_options);

        lib.step.dependOn(&bindings.step);

        // NB: New way to do lib.setOutputDir(). The ../ is important to escape zig-cache/.
        const lib_install = b.addInstallArtifact(lib, .{});
        lib_install.dest_dir = .{ .custom = "../src/clients/go/pkg/native/" ++ name };
        build_step.dependOn(&lib_install.step);
    }
}

fn java_client(
    b: *std.Build,
    build_step: *std.Build.Step,
    mode: Mode,
    vsr_module: *std.Build.Module,
    vsr_options: *std.Build.Step.Options,
) void {
    const java_bindings_generator = b.addExecutable(.{
        .name = "java_bindings",
        .root_source_file = b.path("src/clients/java/java_bindings.zig"),
        .target = b.graph.host,
    });
    java_bindings_generator.root_module.addImport("vsr", vsr_module);
    java_bindings_generator.root_module.addOptions("vsr_options", vsr_options);
    const bindings = Generated.directory(b, .{
        .generator = java_bindings_generator,
        .path = "./src/clients/java/src/main/java/com/tigerbeetle/",
    });

    inline for (platforms) |platform| {
        const cross_target = CrossTarget.parse(.{
            .arch_os_abi = platform[0],
            .cpu_features = platform[2],
        }) catch unreachable;
        const resolved_target = b.resolveTargetQuery(cross_target);

        const lib = b.addSharedLibrary(.{
            .name = "tb_jniclient",
            .root_source_file = b.path("src/clients/java/src/client.zig"),
            .target = resolved_target,
            .optimize = mode,
        });
        lib.linkLibC();

        if (resolved_target.result.os.tag == .windows) {
            lib.linkSystemLibrary("ws2_32");
            lib.linkSystemLibrary("advapi32");
        }

        lib.root_module.addImport("vsr", vsr_module);
        lib.root_module.addOptions("vsr_options", vsr_options);

        lib.step.dependOn(&bindings.step);

        // NB: New way to do lib.setOutputDir(). The ../ is important to escape zig-cache/.
        const lib_install = b.addInstallArtifact(lib, .{});
        lib_install.dest_dir = .{
            .custom = "../src/clients/java/src/main/resources/lib/" ++
                comptime strip_glibc_version(platform[0]),
        };
        build_step.dependOn(&lib_install.step);
    }
}

fn dotnet_client(
    b: *std.Build,
    build_step: *std.Build.Step,
    mode: Mode,
    vsr_module: *std.Build.Module,
    vsr_options: *std.Build.Step.Options,
) void {
    const dotnet_bindings_generator = b.addExecutable(.{
        .name = "dotnet_bindings",
        .root_source_file = b.path("src/clients/dotnet/dotnet_bindings.zig"),
        .target = b.graph.host,
    });
    dotnet_bindings_generator.root_module.addImport("vsr", vsr_module);
    dotnet_bindings_generator.root_module.addOptions("vsr_options", vsr_options);
    const bindings = Generated.file(b, .{
        .generator = dotnet_bindings_generator,
        .path = "./src/clients/dotnet/TigerBeetle/Bindings.cs",
    });

    inline for (platforms) |platform| {
        const cross_target = CrossTarget.parse(.{
            .arch_os_abi = platform[0],
            .cpu_features = platform[2],
        }) catch unreachable;
        const resolved_target = b.resolveTargetQuery(cross_target);

        const lib = b.addSharedLibrary(.{
            .name = "tb_client",
            .root_source_file = b.path("src/tb_client_exports.zig"),
            .target = resolved_target,
            .optimize = mode,
        });
        lib.linkLibC();

        if (resolved_target.result.os.tag == .windows) {
            lib.linkSystemLibrary("ws2_32");
            lib.linkSystemLibrary("advapi32");
        }

        lib.root_module.addOptions("vsr_options", vsr_options);

        lib.step.dependOn(&bindings.step);

        build_step.dependOn(&CopyFile.create(
            b,
            lib.getEmittedBin(),
            b.fmt(
                "./src/clients/dotnet/TigerBeetle/runtimes/{s}/native/{s}",
                .{ platform[1], lib.out_filename },
            ),
            .{},
        ).step);
    }
}

fn node_client(
    b: *std.Build,
    build_step: *std.Build.Step,
    mode: Mode,
    vsr_module: *std.Build.Module,
    vsr_options: *std.Build.Step.Options,
) void {
    const node_bindings_generator = b.addExecutable(.{
        .name = "node_bindings",
        .root_source_file = b.path("src/clients/node/node_bindings.zig"),
        .target = b.graph.host,
    });
    node_bindings_generator.root_module.addImport("vsr", vsr_module);
    node_bindings_generator.root_module.addOptions("vsr_options", vsr_options);
    const bindings = Generated.file(b, .{
        .generator = node_bindings_generator,
        .path = "./src/clients/node/src/bindings.ts",
    });

    // Run `npm install` to get access to node headers.
    var npm_install = b.addSystemCommand(&.{ "npm", "install" });
    npm_install.cwd = b.path("./src/clients/node");

    // For windows, compile a set of all symbols that could be exported by node and write it to a
    // `.def` file for `zig dlltool` to generate a `.lib` file from.
    var write_def_file = b.addSystemCommand(&.{
        "node", "--eval",
        \\const headers = require('node-api-headers')
        \\
        \\const allSymbols = new Set()
        \\for (const ver of Object.values(headers.symbols)) {
        \\    for (const sym of ver.node_api_symbols) {
        \\        allSymbols.add(sym)
        \\    }
        \\    for (const sym of ver.js_native_api_symbols) {
        \\        allSymbols.add(sym)
        \\    }
        \\}
        \\
        \\process.stdout.write('EXPORTS\n    ' + Array.from(allSymbols).join('\n    '))
    });
    write_def_file.cwd = b.path("./src/clients/node");
    write_def_file.step.dependOn(&npm_install.step);

    var run_dll_tool = b.addSystemCommand(&.{
        b.graph.zig_exe, "dlltool",
        "-m",            "i386:x86-64",
        "-D",            "node.exe",
        "-l",            "node.lib",
        "-d",
    });
    run_dll_tool.addFileArg(write_def_file.captureStdOut());
    run_dll_tool.cwd = b.path("./src/clients/node");

    inline for (platforms) |platform| {
        const cross_target = CrossTarget.parse(.{
            .arch_os_abi = platform[0],
            .cpu_features = platform[2],
        }) catch unreachable;
        const resolved_target = b.resolveTargetQuery(cross_target);

        const lib = b.addSharedLibrary(.{
            .name = "tb_nodeclient",
            .root_source_file = b.path("src/node.zig"),
            .target = resolved_target,
            .optimize = mode,
        });
        lib.linkLibC();

        lib.step.dependOn(&npm_install.step);
        lib.addSystemIncludePath(b.path("src/clients/node/node_modules/node-api-headers/include"));
        lib.linker_allow_shlib_undefined = true;

        if (resolved_target.result.os.tag == .windows) {
            lib.linkSystemLibrary("ws2_32");
            lib.linkSystemLibrary("advapi32");

            lib.step.dependOn(&run_dll_tool.step);
            lib.addLibraryPath(b.path("src/clients/node"));
            lib.linkSystemLibrary("node");
        }

        lib.root_module.addOptions("vsr_options", vsr_options);

        lib.step.dependOn(&bindings.step);

        build_step.dependOn(&CopyFile.create(
            b,
            lib.getEmittedBin(),
            "./src/clients/node/dist/bin/" ++
                comptime strip_glibc_version(platform[0]) ++
                "/client.node",
            .{},
        ).step);
    }
}

fn c_client(
    b: *std.Build,
    build_step: *std.Build.Step,
    mode: Mode,
    vsr_options: *std.Build.Step.Options,
    tb_client_header: *Generated,
) void {
    build_step.dependOn(&tb_client_header.step);

    inline for (platforms) |platform| {
        const cross_target = CrossTarget.parse(.{
            .arch_os_abi = platform[0],
            .cpu_features = platform[2],
        }) catch unreachable;
        const resolved_target = b.resolveTargetQuery(cross_target);

        const shared_lib = b.addSharedLibrary(.{
            .name = "tb_client",
            .root_source_file = b.path("src/tb_client_exports.zig"),
            .target = resolved_target,
            .optimize = mode,
        });
        const static_lib = b.addStaticLibrary(.{
            .name = "tb_client",
            .root_source_file = b.path("src/tb_client_exports.zig"),
            .target = resolved_target,
            .optimize = mode,
        });

        static_lib.bundle_compiler_rt = true;
        static_lib.pie = true;

        for ([_]*std.Build.Step.Compile{ shared_lib, static_lib }) |lib| {
            lib.linkLibC();

            if (resolved_target.result.os.tag == .windows) {
                lib.linkSystemLibrary("ws2_32");
                lib.linkSystemLibrary("advapi32");
            }

            lib.root_module.addOptions("vsr_options", vsr_options);

            build_step.dependOn(&CopyFile.create(
                b,
                lib.getEmittedBin(),
                b.fmt("./src/clients/c/lib/{s}/{s}", .{ platform[0], lib.out_filename }),
                .{},
            ).step);
        }
    }
}

/// Steps which unconditionally fails with a message.
///
/// This is useful for cases where at configuration time you can determine that a certain step
/// can't succeeded (e.g., a system library is not preset on the host system), but you only want
/// to fail the step once the user tries to run it. That is, you don't want to fail the whole build,
/// as other steps might run fine.
const FailStep = struct {
    step: std.Build.Step,
    message: []const u8,

    fn add(b: *std.Build, message: []const u8) *FailStep {
        const result = b.allocator.create(FailStep) catch unreachable;
        result.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "failure",
                .owner = b,
                .makeFn = FailStep.make,
            }),
            .message = message,
        };
        return result;
    }

    fn make(step: *std.Build.Step, _: std.Progress.Node) anyerror!void {
        const self: *FailStep = @fieldParentPtr("step", step);
        std.log.err("{s}", .{self.message});
        return error.FailStep;
    }
};

// Patch the target to use the right CPU. This is a somewhat hacky way to do this, but the core idea
// here is to keep this file as the source of truth for what we need from the CPU.
fn set_cpu_features(
    target_requested: *std.Build.ResolvedTarget,
    targets_supported: []const CrossTarget,
) void {
    const target_supported = for (targets_supported) |target_supported| {
        if (target_requested.result.cpu.arch == target_supported.cpu_arch) {
            break target_supported;
        }
    } else @panic("error: unsupported target");

    // CPU model detection from: https://github.com/ziglang/zig/blob/0.13.0/lib/std/zig/system.zig#L320
    target_requested.result.cpu.model = switch (target_supported.cpu_model) {
        .native => @panic("pre-defined supported target assumed runtime-detected cpu model"),
        .baseline,
        .determined_by_cpu_arch,
        => std.Target.Cpu.baseline(target_supported.cpu_arch.?).model,
        .explicit => |model| model,
    };
    target_requested.result.cpu.features.addFeatureSet(target_supported.cpu_features_add);
    target_requested.result.cpu.features.removeFeatureSet(target_supported.cpu_features_sub);
}

/// Set the JVM DLL directory on Windows.
fn set_windows_dll(allocator: std.mem.Allocator, java_home: []const u8) void {
    comptime std.debug.assert(builtin.os.tag == .windows);
    const set_dll_directory = struct {
        pub extern "kernel32" fn SetDllDirectoryA(
            path: [*:0]const u8,
        ) callconv(.C) std.os.windows.BOOL;
    }.SetDllDirectoryA;

    const java_bin_path = std.fs.path.joinZ(
        allocator,
        &.{ java_home, "\\bin" },
    ) catch unreachable;
    _ = set_dll_directory(java_bin_path);

    const java_bin_server_path = std.fs.path.joinZ(
        allocator,
        &.{ java_home, "\\bin\\server" },
    ) catch unreachable;
    _ = set_dll_directory(java_bin_server_path);
}

// Zig's `install` step is used for installation inside a user-override prefix (zig-out by default).
// In contrast, `CopyFile` installs a file into a specific location, which we need for:
// * lifting the build binary out of `./zig-out/bin/tigerbeetle` to just `./tigerbeetle`
// * placing compiled `.so` for client libraries in a place where runtimes like Node can find them.
const CopyFile = struct {
    step: std.Build.Step,
    source: std.Build.LazyPath,
    dest_path: []const u8,
    generated: std.Build.GeneratedFile,
    enforce_already_installed: bool,

    pub fn create(
        owner: *std.Build,
        source: std.Build.LazyPath,
        destination: []const u8,
        options: struct {
            enforce_already_installed: bool = false,
        },
    ) *CopyFile {
        assert(destination.len != 0);
        assert(!std.fs.path.isAbsolute(destination));
        const dest_path = owner.pathFromRoot(destination);

        const install = owner.allocator.create(CopyFile) catch @panic("OOM");
        install.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = owner.fmt(
                    "install {s} to {s}",
                    .{ source.getDisplayName(), dest_path },
                ),
                .owner = owner,
                .makeFn = make,
            }),
            .source = source.dupe(owner),
            .dest_path = owner.dupePath(dest_path),
            .generated = .{
                .step = &install.step,
                .path = dest_path,
            },
            .enforce_already_installed = options.enforce_already_installed,
        };
        source.addStepDependencies(&install.step);
        return install;
    }

    pub fn getDest(self: *CopyFile) std.Build.LazyPath {
        return .{ .generated = .{ .file = &self.generated } };
    }

    fn make(step: *std.Build.Step, prog_node: std.Progress.Node) !void {
        _ = prog_node;
        const b = step.owner;
        const install: *CopyFile = @fieldParentPtr("step", step);
        const full_src_path = install.source.getPath2(b, step);
        const cwd = std.fs.cwd();

        if (install.enforce_already_installed) {
            const src = try std.fs.cwd().readFileAlloc(
                step.owner.allocator,
                full_src_path,
                std.math.maxInt(usize),
            );
            defer step.owner.allocator.free(src);

            const dest = try std.fs.cwd().readFileAlloc(
                step.owner.allocator,
                install.dest_path,
                std.math.maxInt(usize),
            );
            defer step.owner.allocator.free(dest);

            if (!std.mem.eql(u8, src, dest)) return step.fail(
                "file '{s}' differs from source '{s}'",
                .{ install.dest_path, full_src_path },
            );
            step.result_cached = true;
            return;
        }

        const prev = std.fs.Dir.updateFile(
            cwd,
            full_src_path,
            cwd,
            install.dest_path,
            .{},
        ) catch |err| {
            return step.fail("unable to update file from '{s}' to '{s}': {s}", .{
                full_src_path, install.dest_path, @errorName(err),
            });
        };
        step.result_cached = prev == .fresh;
    }
};

/// Code generation for files which must also be committed to the repository.
///
/// Runs the generator program to produce a file or a directory and copies the result to the
/// destination directory within the source tree.
///
/// On CI (when CI env var is set), the files are not updated, and merely checked for freshness.
const Generated = struct {
    step: std.Build.Step,
    path: std.Build.LazyPath,

    destination: []const u8,
    generated_file: std.Build.GeneratedFile,
    source: std.Build.LazyPath,
    mode: enum { file, directory },

    /// The `generator` program prints the file to stdout.
    pub fn file(b: *std.Build, options: struct {
        generator: *std.Build.Step.Compile,
        path: []const u8,
    }) *Generated {
        return create(b, options.path, .{
            .file = options.generator,
        });
    }

    pub fn file_copy(b: *std.Build, options: struct {
        from: std.Build.LazyPath,
        path: []const u8,
    }) *Generated {
        return create(b, options.path, .{
            .copy = options.from,
        });
    }

    /// The `generator` program creates several files in the output directory, which is passed in
    /// as an argument.
    ///
    /// NB: there's no check that there aren't extra file at the destination. In other words, this
    /// API can be used for mixing generated and hand-written files in a single directory.
    pub fn directory(b: *std.Build, options: struct {
        generator: *std.Build.Step.Compile,
        path: []const u8,
    }) *Generated {
        return create(b, options.path, .{
            .directory = options.generator,
        });
    }

    fn create(b: *std.Build, destination: []const u8, generator: union(enum) {
        file: *std.Build.Step.Compile,
        directory: *std.Build.Step.Compile,
        copy: std.Build.LazyPath,
    }) *Generated {
        assert(std.mem.startsWith(u8, destination, "./src"));
        const result = b.allocator.create(Generated) catch @panic("OOM");
        result.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = b.fmt("generate {s}", .{std.fs.path.basename(destination)}),
                .owner = b,
                .makeFn = make,
            }),
            .path = .{ .generated = .{ .file = &result.generated_file } },

            .destination = destination,
            .generated_file = .{ .step = &result.step },
            .source = switch (generator) {
                .file => |compile| b.addRunArtifact(compile).captureStdOut(),
                .directory => |compile| b.addRunArtifact(compile).addOutputDirectoryArg("out"),
                .copy => |lazy_path| lazy_path,
            },
            .mode = switch (generator) {
                .file, .copy => .file,
                .directory => .directory,
            },
        };
        result.source.addStepDependencies(&result.step);

        return result;
    }

    fn make(step: *std.Build.Step, prog_node: std.Progress.Node) !void {
        _ = prog_node;
        const b = step.owner;
        const generated: *Generated = @fieldParentPtr("step", step);
        const ci = try std.process.hasEnvVar(b.allocator, "CI");
        const source_path = generated.source.getPath2(b, step);

        if (ci) {
            const fresh = switch (generated.mode) {
                .file => file_fresh(b, source_path, generated.destination),
                .directory => directory_fresh(b, source_path, generated.destination),
            } catch |err| {
                return step.fail("unable to check '{s}': {s}", .{
                    generated.destination, @errorName(err),
                });
            };

            if (!fresh) {
                return step.fail("file '{s}' is outdated", .{
                    generated.destination,
                });
            }
            step.result_cached = true;
        } else {
            const prev = switch (generated.mode) {
                .file => file_update(b, source_path, generated.destination),
                .directory => directory_update(b, source_path, generated.destination),
            } catch |err| {
                return step.fail("unable to update '{s}': {s}", .{
                    generated.destination, @errorName(err),
                });
            };
            step.result_cached = prev == .fresh;
        }

        generated.generated_file.path = generated.destination;
    }

    fn file_fresh(
        b: *std.Build,
        source_path: []const u8,
        target_path: []const u8,
    ) !bool {
        const want = try b.build_root.handle.readFileAlloc(
            b.allocator,
            source_path,
            std.math.maxInt(usize),
        );
        defer b.allocator.free(want);

        const got = b.build_root.handle.readFileAlloc(
            b.allocator,
            target_path,
            std.math.maxInt(usize),
        ) catch return false;
        defer b.allocator.free(got);

        return std.mem.eql(u8, want, got);
    }

    fn file_update(
        b: *std.Build,
        source_path: []const u8,
        target_path: []const u8,
    ) !std.fs.Dir.PrevStatus {
        return std.fs.Dir.updateFile(
            b.build_root.handle,
            source_path,
            b.build_root.handle,
            target_path,
            .{},
        );
    }

    fn directory_fresh(
        b: *std.Build,
        source_path: []const u8,
        target_path: []const u8,
    ) !bool {
        var source_dir = try b.build_root.handle.openDir(source_path, .{ .iterate = true });
        defer source_dir.close();

        var target_dir = b.build_root.handle.openDir(target_path, .{}) catch return false;
        defer target_dir.close();

        var source_iter = source_dir.iterate();
        while (try source_iter.next()) |entry| {
            assert(entry.kind == .file);
            const want = try source_dir.readFileAlloc(
                b.allocator,
                entry.name,
                std.math.maxInt(usize),
            );
            defer b.allocator.free(want);

            const got = target_dir.readFileAlloc(
                b.allocator,
                entry.name,
                std.math.maxInt(usize),
            ) catch return false;
            defer b.allocator.free(got);

            if (!std.mem.eql(u8, want, got)) return false;
        }

        return true;
    }

    fn directory_update(
        b: *std.Build,
        source_path: []const u8,
        target_path: []const u8,
    ) !std.fs.Dir.PrevStatus {
        var result: std.fs.Dir.PrevStatus = .fresh;
        var source_dir = try b.build_root.handle.openDir(source_path, .{ .iterate = true });
        defer source_dir.close();

        var target_dir = try b.build_root.handle.makeOpenPath(target_path, .{});
        defer target_dir.close();

        var source_iter = source_dir.iterate();
        while (try source_iter.next()) |entry| {
            assert(entry.kind == .file);
            const status = try std.fs.Dir.updateFile(
                source_dir,
                entry.name,
                target_dir,
                entry.name,
                .{},
            );
            if (status == .stale) result = .stale;
        }

        return result;
    }
};
