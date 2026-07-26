const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 构建信息注入: 版本跟随 git tag，附带提交哈希与构建时间 (proxy -v 显示)
    const version = b.option([]const u8, "version", "版本号 (默认取 git describe)") orelse
        detectVersion(b);
    const commit = gitOutput(b, &.{ "git", "rev-parse", "--short", "HEAD" }) orelse "unknown";
    const build_opts = b.addOptions();
    build_opts.addOption([]const u8, "version", version);
    build_opts.addOption([]const u8, "commit", commit);
    build_opts.addOption([]const u8, "build_time", buildTimestamp(b));

    const exe = b.addExecutable(.{
        .name = "proxy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .Debug,
        }),
    });

    exe.root_module.addOptions("build_info", build_opts);
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
            .strip = optimize != .Debug,
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
            .strip = true,
        }),
    });

    release_exe.root_module.addOptions("build_info", build_opts);
    const release_install = b.addInstallArtifact(release_exe, .{});
    const release_step = b.step("release", "Build optimized release binary");
    release_step.dependOn(&release_install.step);

    const fast_exe = b.addExecutable(.{
        .name = "proxy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .strip = true,
        }),
    });

    fast_exe.root_module.addOptions("build_info", build_opts);
    const fast_install = b.addInstallArtifact(fast_exe, .{});
    const fast_step = b.step("fast", "Build with ReleaseFast optimization");
    fast_step.dependOn(&fast_install.step);

    const small_exe = b.addExecutable(.{
        .name = "proxy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseSmall,
            .strip = true,
        }),
    });

    small_exe.root_module.addOptions("build_info", build_opts);
    const small_install = b.addInstallArtifact(small_exe, .{});
    const small_step = b.step("small", "Build with ReleaseSmall optimization");
    small_step.dependOn(&small_install.step);

    const safe_exe = b.addExecutable(.{
        .name = "proxy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .strip = true,
        }),
    });

    safe_exe.root_module.addOptions("build_info", build_opts);
    const safe_install = b.addInstallArtifact(safe_exe, .{});
    const safe_step = b.step("safe", "Build with ReleaseSafe optimization");
    safe_step.dependOn(&safe_install.step);
}

/// 版本号: git describe 跟随最近的 tag，去掉前缀 v；仓库不可用时退回 dev
fn detectVersion(b: *std.Build) []const u8 {
    const described = gitOutput(b, &.{ "git", "describe", "--tags", "--always", "--dirty" }) orelse
        return "dev";
    return std.mem.trimLeft(u8, described, "v");
}

fn gitOutput(b: *std.Build, argv: []const []const u8) ?[]const u8 {
    // 失败 (含非零退出码) 直接走 error 分支，成功时 out_code 不会被写入
    var code: u8 = 0;
    const out = b.runAllowFail(argv, &code, .Ignore) catch return null;
    const trimmed = std.mem.trim(u8, out, " \r\n");
    if (trimmed.len == 0) return null;
    return trimmed;
}

fn buildTimestamp(b: *std.Build) []const u8 {
    const secs: u64 = @intCast(std.time.timestamp());
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return b.fmt("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC", .{
        yd.year,
        md.month.numeric(),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
    });
}
