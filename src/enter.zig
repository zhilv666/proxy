//! proxy on —— 进入一个注入了代理环境变量的交互子 shell。
//!
//! 子进程不能修改父 shell 环境,所以"在当前 shell 敲命令自动带代理"无法零痕迹实现。
//! 本模块换一种同样直观的形态:spawn 一个新的交互 shell,启动前把代理变量
//! (http_proxy / https_proxy / all_proxy)注入到它的环境里并覆盖外部同名变量。
//! 于是:
//!   - 子 shell 里敲的命令读到的 env 是注入后的这份,不再读外面的
//!   - 外面的环境不受影响,exit / Ctrl+D 即返回原 shell
//!   - 历史天然共享:仍是同一个用户、同一个 HISTFILE / PSReadLine 历史,进出互通
//!   - 不需要 eval/iex,也不挑 shell 语法 (env 直接注入,不生成脚本)
//!
//! 它是"子 shell"而非真正的 screen/tmux:不能 detach 后跑开再回来。
//! 那需要伪终端/会话复用 (Unix 可自研,Windows 需常驻 server + ConPTY,工程量很大)。
const std = @import("std");
const builtin = @import("builtin");
const Config = @import("config.zig");
const output = @import("output.zig");

const is_windows = builtin.os.tag == .windows;

/// 主入口: 进入带代理的子 shell。
/// 代理 URL 取自当前配置 (若处于临时节点覆盖,则是该节点)。
pub fn run(allocator: std.mem.Allocator) !void {
    var config = try Config.load(allocator);
    defer config.deinit();
    const url = try config.buildProxyUrl(allocator);
    defer allocator.free(url);

    // 注入代理环境: 子 shell 从这里读,不再看外面的
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    try Config.putProxyEnv(&env_map, url);

    const shell_argv = try shellArgv(allocator);
    defer {
        for (shell_argv) |a| allocator.free(a);
        allocator.free(shell_argv);
    }

    const writer = try output.getWriter();
    try writer.print("▶ 已进入代理子 shell (代理 {s})\n", .{url});
    try writer.writeAll("  此终端里敲的命令走该代理;exit / Ctrl+D 返回原环境\n");

    var child = std.process.Child.init(shell_argv, allocator);
    child.env_map = &env_map;
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = child.spawnAndWait() catch |err| {
        output.print("启动子 shell 失败: {s}\n", .{@errorName(err)});
        return;
    };
    switch (term) {
        .Exited => |c| std.process.exit(c),
        else => std.process.exit(0),
    }
}

/// 探测并组装交互 shell 的 argv (每段都在 allocator 上分配,调用方整体释放)。
///
/// 优先级:
///   1. Windows 下 MSYSTEM 已设 (Git Bash / MSYS2) → bash (该信号比 $SHELL 稳定:
///      Git Bash 派生原生 exe 时 $SHELL 时有时无,MSYSTEM 恒定存在)
///   2. $SHELL 已设 (Unix 用户 / 显式指定) → 取其 basename 按 PATH 找
///      (直接拿 /bin/bash.exe 这类 MSYS 路径给原生 spawn 会失败)
///   3. 平台默认 → Windows: PowerShell → cmd;Unix: bash → sh
///   裸启动即可进交互模式 (bash/zsh/pwsh/cmd 不带参数时默认交互)。
fn shellArgv(allocator: std.mem.Allocator) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .{};
    errdefer {
        for (list.items) |a| allocator.free(a);
        list.deinit(allocator);
    }

    // 1. Git Bash / MSYS2 信号: 直接按名字 bash (经 PATH 解析到 Git 的 bash.exe)
    if (is_windows and envIsSet(allocator, "MSYSTEM")) {
        try list.append(allocator, try allocator.dupe(u8, "bash"));
        return list.toOwnedSlice(allocator);
    }

    // 2. $SHELL: 取 basename 按 PATH spawn
    if (std.process.getEnvVarOwned(allocator, "SHELL")) |shell| {
        defer allocator.free(shell);
        const base = std.fs.path.basename(shell); // 去目录; 原样经 PATH 找
        try list.append(allocator, try allocator.dupe(u8, base));
        return list.toOwnedSlice(allocator);
    } else |_| {}

    if (is_windows) {
        if (commandExists(allocator, "pwsh")) {
            try list.append(allocator, try allocator.dupe(u8, "pwsh"));
        } else if (commandExists(allocator, "powershell")) {
            try list.append(allocator, try allocator.dupe(u8, "powershell"));
        } else {
            try list.append(allocator, try allocator.dupe(u8, "cmd"));
        }
    } else if (commandExists(allocator, "bash")) {
        try list.append(allocator, try allocator.dupe(u8, "bash"));
    } else {
        try list.append(allocator, try allocator.dupe(u8, "sh"));
    }

    return list.toOwnedSlice(allocator);
}

/// 环境变量是否存在 (不关心值)。
fn envIsSet(allocator: std.mem.Allocator, name: []const u8) bool {
    if (std.process.getEnvVarOwned(allocator, name)) |v| {
        allocator.free(v);
        return true;
    } else |_| return false;
}

fn commandExists(allocator: std.mem.Allocator, name: []const u8) bool {
    const finder = if (is_windows) "where" else "which";
    var child = std.process.Child.init(&.{ finder, name }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    const term = child.spawnAndWait() catch return false;
    return switch (term) {
        .Exited => |c| c == 0,
        else => false,
    };
}
