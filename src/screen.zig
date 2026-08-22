//! 会话管理: 把当前节点的代理环境注入到 screen / tmux 会话，
//! detach/reattach 等交互由后端原生提供 (screen 前缀键 Ctrl+A，tmux 已对齐为 Ctrl+A)。
//! 未检测到 screen/tmux 时回退为「开一个带代理环境的新终端/子 shell」。
const std = @import("std");
const builtin = @import("builtin");
const Config = @import("config.zig");
const output = @import("output.zig");

const is_windows = builtin.os.tag == .windows;

/// 会话名统一加此前缀，list 只筛这类，避免污染用户自建的 screen/tmux 会话。
pub const prefix = "proxy-";

pub const Backend = enum { screen, tmux, none };

/// 探测可用后端: 优先 screen，其次 tmux，都没有返回 none。
pub fn detectBackend(allocator: std.mem.Allocator) Backend {
    if (commandExists(allocator, "screen")) return .screen;
    if (commandExists(allocator, "tmux")) return .tmux;
    return .none;
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

/// 拼出带前缀的完整会话名: proxy-<name>
pub fn sessionName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, name });
}

/// 从后端 list 输出里提取 proxy- 会话的短名 (去掉前缀)。
/// 调用方负责释放返回切片及其中每个元素。
pub fn extractSessions(
    allocator: std.mem.Allocator,
    backend: Backend,
    text: []const u8,
) ![][]u8 {
    var names: std.ArrayList([]u8) = .{};
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;

        const full: []const u8 = switch (backend) {
            // screen: "12345.proxy-dev\t(Detached)" —— socket 名在首个 '.' 之后
            .screen => blk: {
                var it = std.mem.tokenizeAny(u8, line, " \t");
                const tok = it.next() orelse continue;
                const dot = std.mem.indexOfScalar(u8, tok, '.') orelse continue;
                break :blk tok[dot + 1 ..];
            },
            // tmux: "proxy-dev: 1 windows (...)" —— 名字在首个 ':' 之前
            .tmux => blk: {
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                break :blk line[0..colon];
            },
            .none => continue,
        };

        if (!std.mem.startsWith(u8, full, prefix)) continue;
        try names.append(allocator, try allocator.dupe(u8, full[prefix.len..]));
    }

    return names.toOwnedSlice(allocator);
}

/// 构造注入了代理环境变量的 env map (调用方负责 deinit)。
fn proxyEnv(allocator: std.mem.Allocator, url: []const u8) !std.process.EnvMap {
    var env = try std.process.getEnvMap(allocator);
    errdefer env.deinit();
    try Config.putProxyEnv(&env, url);
    return env;
}

// ---------------------------------------------------------------------------
// 命令入口
// ---------------------------------------------------------------------------

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len > 0 and (std.mem.eql(u8, args[0], "-h") or std.mem.eql(u8, args[0], "--help"))) {
        printHelp();
        return;
    }

    const backend = detectBackend(allocator);

    // 子命令分发
    if (args.len > 0) {
        if (std.mem.eql(u8, args[0], "ls") or std.mem.eql(u8, args[0], "list")) {
            try listSessions(allocator, backend);
            return;
        }
        if (std.mem.eql(u8, args[0], "-r") or std.mem.eql(u8, args[0], "attach")) {
            if (args.len < 2) {
                output.print("错误: 需要提供会话名\n用法: proxy screen -r <名称>\n", .{});
                return;
            }
            try attachSession(allocator, backend, args[1]);
            return;
        }
        if (std.mem.eql(u8, args[0], "kill") or std.mem.eql(u8, args[0], "rm")) {
            if (args.len < 2) {
                output.print("错误: 需要提供会话名\n用法: proxy screen kill <名称>\n", .{});
                return;
            }
            try killSession(allocator, backend, args[1]);
            return;
        }
    }

    // 无子命令 → 创建/进入会话，名字默认取当前节点名
    const name = if (args.len > 0) args[0] else try defaultName(allocator);
    const owned = args.len == 0;
    defer if (owned) allocator.free(name);
    try createSession(allocator, backend, name);
}

/// 会话默认名: 当前激活节点名，无节点则 "default"。
fn defaultName(allocator: std.mem.Allocator) ![]u8 {
    var config = try Config.load(allocator);
    defer config.deinit();
    if (config.node.len > 0) return allocator.dupe(u8, config.node);
    return allocator.dupe(u8, "default");
}

fn createSession(allocator: std.mem.Allocator, backend: Backend, name: []const u8) !void {
    var config = try Config.load(allocator);
    defer config.deinit();
    const url = try config.buildProxyUrl(allocator);
    defer allocator.free(url);

    var env = try proxyEnv(allocator, url);
    defer env.deinit();

    const full = try sessionName(allocator, name);
    defer allocator.free(full);

    switch (backend) {
        .screen => {
            output.print("▶ 启动 screen 会话 {s} (代理 {s})\n  分离: Ctrl+A D  重连: proxy screen -r {s}\n", .{ full, url, name });
            // -D -R: 已存在则重连 (必要时先分离别处)，不存在则新建
            try spawnInteractive(allocator, &.{ "screen", "-D", "-R", full }, &env);
        },
        .tmux => {
            output.print("▶ 启动 tmux 会话 {s} (代理 {s})\n  分离: Ctrl+A D  重连: proxy screen -r {s}\n", .{ full, url, name });
            // -A: 已存在则等价 attach；顺带把前缀键对齐为 Ctrl+A
            try spawnInteractive(allocator, &.{
                "tmux",          "new-session", "-A",     "-s", full,
                ";",             "set",         "-g",     "prefix", "C-a",
                ";",             "bind",        "C-a",    "send-prefix",
            }, &env);
        },
        .none => try fallbackWindow(allocator, name, url, &env),
    }
}

fn attachSession(allocator: std.mem.Allocator, backend: Backend, name: []const u8) !void {
    const full = try sessionName(allocator, name);
    defer allocator.free(full);

    switch (backend) {
        .screen => try spawnInteractive(allocator, &.{ "screen", "-r", full }, null),
        .tmux => try spawnInteractive(allocator, &.{ "tmux", "attach", "-t", full }, null),
        .none => output.print("未检测到 screen/tmux，无法重连会话。\n", .{}),
    }
}

fn killSession(allocator: std.mem.Allocator, backend: Backend, name: []const u8) !void {
    const full = try sessionName(allocator, name);
    defer allocator.free(full);

    const argv: []const []const u8 = switch (backend) {
        .screen => &.{ "screen", "-S", full, "-X", "quit" },
        .tmux => &.{ "tmux", "kill-session", "-t", full },
        .none => {
            output.print("未检测到 screen/tmux。\n", .{});
            return;
        },
    };

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    const term = child.spawnAndWait() catch {
        output.print("结束会话失败: {s}\n", .{full});
        return;
    };
    switch (term) {
        .Exited => |c| if (c == 0) {
            output.print("✓ 会话已结束: {s}\n", .{full});
        } else {
            output.print("会话不存在或已结束: {s}\n", .{full});
        },
        else => output.print("会话不存在或已结束: {s}\n", .{full}),
    }
}

fn listSessions(allocator: std.mem.Allocator, backend: Backend) !void {
    if (backend == .none) {
        output.print("未检测到 screen/tmux，无会话可列出。\n安装 screen 或 tmux 可启用会话保持。\n", .{});
        return;
    }

    const argv: []const []const u8 = switch (backend) {
        .screen => &.{ "screen", "-ls" },
        .tmux => &.{ "tmux", "ls" },
        .none => unreachable,
    };

    const text = runCapture(allocator, argv) catch {
        output.print("无法列出会话。\n", .{});
        return;
    };
    defer allocator.free(text);

    const names = try extractSessions(allocator, backend, text);
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }

    if (names.len == 0) {
        output.print("暂无 proxy 会话。用 proxy screen [名称] 创建。\n", .{});
        return;
    }

    output.print("proxy 会话 ({s}):\n\n", .{@tagName(backend)});
    for (names) |n| {
        output.print("  {s}    重连: proxy screen -r {s}\n", .{ n, n });
    }
}

// ---------------------------------------------------------------------------
// 进程辅助
// ---------------------------------------------------------------------------

/// 启动一个继承终端 (交互) 的子进程，可选注入 env。等待其退出。
fn spawnInteractive(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    env: ?*std.process.EnvMap,
) !void {
    var child = std.process.Child.init(argv, allocator);
    if (env) |e| child.env_map = e;
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    _ = child.spawnAndWait() catch |err| {
        output.print("启动失败: {s}\n", .{@errorName(err)});
        return;
    };
}

/// 运行命令并捕获 stdout (screen -ls 退出码不可靠，只看输出)。
fn runCapture(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(allocator, 1 << 20);
    errdefer allocator.free(out);
    _ = try child.wait();
    return out;
}

/// 无 screen/tmux 时的回退: 开一个带代理环境的新窗口 (Windows) 或子 shell。
fn fallbackWindow(
    allocator: std.mem.Allocator,
    name: []const u8,
    url: []const u8,
    env: *std.process.EnvMap,
) !void {
    _ = name;
    if (is_windows) {
        output.print("未检测到 screen/tmux，已开一个带代理的新窗口 (代理 {s})。\n提示: 安装 tmux 可获得会话分离/重连能力。\n", .{url});
        // start 会新开进程并继承当前环境 (含注入的代理变量)
        try spawnInteractive(allocator, &.{ "cmd", "/c", "start", "", "cmd", "/k" }, env);
    } else {
        const shell = env.get("SHELL") orelse "/bin/sh";
        output.print("未检测到 screen/tmux，已在带代理的子 shell 中运行 (代理 {s})。\n提示: 安装 screen/tmux 可获得会话分离/重连能力。exit 退出。\n", .{url});
        try spawnInteractive(allocator, &.{shell}, env);
    }
}

fn printHelp() void {
    const help =
        \\proxy screen - 带代理的会话管理 (包装 screen / tmux)
        \\
        \\用法:
        \\  proxy screen [名称]        创建并进入带代理的会话 (默认名 = 当前节点)
        \\  proxy screen ls            列出所有 proxy 会话
        \\  proxy screen -r <名称>     重新连接会话
        \\  proxy screen kill <名称>   结束会话
        \\
        \\会话内所有命令自动走当前节点的代理。分离/重连由后端提供:
        \\  screen: Ctrl+A D 分离      tmux: Ctrl+A D 分离 (已对齐前缀键)
        \\
        \\未安装 screen/tmux 时回退为「开一个带代理的新窗口/子 shell」(无会话保持)。
        \\
        \\示例:
        \\  proxy switch hk && proxy screen        # 开一个走 hk 代理的会话
        \\  proxy screen dev                       # 命名会话 dev
        \\  proxy screen -r dev                    # 重连
        \\
    ;
    output.print("{s}", .{help});
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

test "sessionName 加前缀" {
    const a = std.testing.allocator;
    const s = try sessionName(a, "hk");
    defer a.free(s);
    try std.testing.expectEqualStrings("proxy-hk", s);
}

test "extractSessions 解析 screen -ls 输出，只留 proxy- 会话" {
    const a = std.testing.allocator;
    const text =
        "There are screens on:\n" ++
        "\t12345.proxy-dev\t(Detached)\n" ++
        "\t12346.proxy-hk\t(Attached)\n" ++
        "\t99999.mywork\t(Detached)\n" ++
        "3 Sockets in /run/screen.\n";
    const names = try extractSessions(a, .screen, text);
    defer {
        for (names) |n| a.free(n);
        a.free(names);
    }
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("dev", names[0]);
    try std.testing.expectEqualStrings("hk", names[1]);
}

test "extractSessions 解析 tmux ls 输出" {
    const a = std.testing.allocator;
    const text =
        "proxy-dev: 1 windows (created Sun Jul 26)\n" ++
        "work: 2 windows (created Sun Jul 26) (attached)\n" ++
        "proxy-hk: 1 windows\n";
    const names = try extractSessions(a, .tmux, text);
    defer {
        for (names) |n| a.free(n);
        a.free(names);
    }
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("dev", names[0]);
    try std.testing.expectEqualStrings("hk", names[1]);
}

test "extractSessions 空输入返回空" {
    const a = std.testing.allocator;
    const names = try extractSessions(a, .screen, "No Sockets found.\n");
    defer {
        for (names) |n| a.free(n);
        a.free(names);
    }
    try std.testing.expectEqual(@as(usize, 0), names.len);
}
