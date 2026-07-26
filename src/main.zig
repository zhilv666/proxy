const std = @import("std");
const Config = @import("config.zig");
const Alias = @import("alias.zig");
const Tui = @import("tui.zig");
const output = @import("output.zig");

const VERSION = "1.0.0";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printHelp();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "--help")) {
        printHelp();
    } else if (std.mem.eql(u8, command, "-v") or std.mem.eql(u8, command, "--version")) {
        output.print("proxy version {s}\n", .{VERSION});
    } else if (std.mem.eql(u8, command, "config")) {
        try handleConfig(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "alias")) {
        try handleAlias(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "tui")) {
        try Tui.run(allocator);
    } else {
        // Execute command with proxy
        try execWithProxy(allocator, args[1..]);
    }
}

fn printHelp() void {
    const help =
        \\proxy - 跨平台代理工具
        \\
        \\用法:
        \\  proxy [命令] [参数...]
        \\
        \\命令:
        \\  config              配置管理
        \\  alias               别名管理
        \\  tui                 启动 TUI 界面
        \\  <command> [args]    使用代理执行命令
        \\
        \\选项:
        \\  -h, --help          显示帮助信息
        \\  -v, --version       显示版本信息
        \\
        \\示例:
        \\  proxy curl https://google.com
        \\  proxy ll
        \\  proxy config set host 127.0.0.1
        \\  proxy alias add windows ll "ls -l"
        \\
    ;
    output.print("{s}", .{help});
}

fn handleConfig(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        printConfigHelp();
        return;
    }

    const subcommand = args[0];

    if (std.mem.eql(u8, subcommand, "-h") or std.mem.eql(u8, subcommand, "--help")) {
        printConfigHelp();
    } else if (std.mem.eql(u8, subcommand, "set")) {
        if (args.len < 3) {
            output.print("错误: 需要提供 key 和 value\n用法: proxy config set <key> <value>\n", .{});
            return;
        }
        try Config.set(allocator, args[1], args[2]);
        output.print("配置已保存: {s} = {s}\n", .{ args[1], args[2] });
    } else if (std.mem.eql(u8, subcommand, "get")) {
        if (args.len < 2) {
            output.print("错误: 需要提供 key\n用法: proxy config get <key>\n", .{});
            return;
        }
        const value = try Config.get(allocator, args[1]);
        if (value) |v| {
            defer allocator.free(v);
            output.print("{s} = {s}\n", .{ args[1], v });
        } else {
            output.print("{s} 未设置\n", .{args[1]});
        }
    } else if (std.mem.eql(u8, subcommand, "list")) {
        try Config.list(allocator);
    } else {
        output.print("未知的子命令: {s}\n", .{subcommand});
        printConfigHelp();
    }
}

fn printConfigHelp() void {
    const help =
        \\proxy config - 配置管理
        \\
        \\用法:
        \\  proxy config <子命令> [参数...]
        \\
        \\子命令:
        \\  set <key> <value>   设置配置项
        \\  get <key>           获取配置项
        \\  list                列出所有配置
        \\
        \\配置项:
        \\  host                代理主机 (默认: 127.0.0.1)
        \\  port                代理端口 (默认: 7890)
        \\  protocol            代理协议 (默认: http)
        \\  username            代理用户名
        \\  password            代理密码
        \\
        \\示例:
        \\  proxy config set host 127.0.0.1
        \\  proxy config set port 7890
        \\  proxy config set username myuser
        \\  proxy config list
        \\
    ;
    output.print("{s}", .{help});
}

fn handleAlias(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        printAliasHelp();
        return;
    }

    const subcommand = args[0];

    if (std.mem.eql(u8, subcommand, "-h") or std.mem.eql(u8, subcommand, "--help")) {
        printAliasHelp();
    } else if (std.mem.eql(u8, subcommand, "add")) {
        if (args.len < 4) {
            output.print("错误: 需要提供平台、别名和命令\n用法: proxy alias add <platform> <alias> <command>\n", .{});
            return;
        }
        try Alias.add(allocator, args[1], args[2], args[3]);
        output.print("别名已添加: {s} ({s}) -> {s}\n", .{ args[2], args[1], args[3] });
    } else if (std.mem.eql(u8, subcommand, "remove")) {
        if (args.len < 3) {
            output.print("错误: 需要提供平台和别名\n用法: proxy alias remove <platform> <alias>\n", .{});
            return;
        }
        try Alias.remove(allocator, args[1], args[2]);
        output.print("别名已删除: {s} ({s})\n", .{ args[2], args[1] });
    } else if (std.mem.eql(u8, subcommand, "list")) {
        try Alias.list(allocator);
    } else {
        output.print("未知的子命令: {s}\n", .{subcommand});
        printAliasHelp();
    }
}

fn printAliasHelp() void {
    const help =
        \\proxy alias - 别名管理
        \\
        \\用法:
        \\  proxy alias <子命令> [参数...]
        \\
        \\子命令:
        \\  add <platform> <alias> <command>    添加别名
        \\  remove <platform> <alias>           删除别名
        \\  list                                列出所有别名
        \\
        \\平台:
        \\  windows, linux, macos, all          all 表示所有平台
        \\
        \\示例:
        \\  proxy alias add linux ll "ls -l"
        \\  proxy alias add windows ll "dir"
        \\  proxy alias add all gs "git status"
        \\  proxy alias remove linux ll
        \\  proxy alias list
        \\
    ;
    output.print("{s}", .{help});
}

fn execWithProxy(allocator: std.mem.Allocator, args: []const []const u8) !void {
    // Load config
    var config = try Config.load(allocator);
    defer config.deinit();

    // Check if first arg is an alias
    const resolved_args = try Alias.resolve(allocator, args);
    defer {
        for (resolved_args) |arg| {
            allocator.free(arg);
        }
        allocator.free(resolved_args);
    }

    // Build proxy URL
    const proxy_url = try config.buildProxyUrl(allocator);
    defer allocator.free(proxy_url);

    // Set up environment
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    try env_map.put("http_proxy", proxy_url);
    try env_map.put("https_proxy", proxy_url);
    try env_map.put("HTTP_PROXY", proxy_url);
    try env_map.put("HTTPS_PROXY", proxy_url);
    try env_map.put("ALL_PROXY", proxy_url);
    try env_map.put("all_proxy", proxy_url);

    // Execute command
    var child = std.process.Child.init(resolved_args, allocator);
    child.env_map = &env_map;
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = try child.spawnAndWait();
    std.process.exit(term.Exited);
}
