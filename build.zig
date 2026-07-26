const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "proxy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Unit tests (tui.zig pulls in term.zig tests)
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tui.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // TUI Demo executable
    const tui_demo_exe = b.addExecutable(.{
        .name = "tui_demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/tui_demo.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(tui_demo_exe);

    const tui_demo_run = b.addRunArtifact(tui_demo_exe);
    tui_demo_run.step.dependOn(b.getInstallStep());

    const tui_demo_step = b.step("demo", "Run the TUI demo");
    tui_demo_step.dependOn(&tui_demo_run.step);

    // Build steps for different optimization levels
    const release_exe = b.addExecutable(.{
        .name = "proxy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });

    const release_install = b.addInstallArtifact(release_exe, .{});
    const release_step = b.step("release", "Build optimized release binary");
    release_step.dependOn(&release_install.step);

    const fast_exe = b.addExecutable(.{
        .name = "proxy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });

    const fast_install = b.addInstallArtifact(fast_exe, .{});
    const fast_step = b.step("fast", "Build with ReleaseFast optimization");
    fast_step.dependOn(&fast_install.step);

    const small_exe = b.addExecutable(.{
        .name = "proxy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseSmall,
        }),
    });

    const small_install = b.addInstallArtifact(small_exe, .{});
    const small_step = b.step("small", "Build with ReleaseSmall optimization");
    small_step.dependOn(&small_install.step);

    const safe_exe = b.addExecutable(.{
        .name = "proxy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
    });

    const safe_install = b.addInstallArtifact(safe_exe, .{});
    const safe_step = b.step("safe", "Build with ReleaseSafe optimization");
    safe_step.dependOn(&safe_install.step);
}
