const std = @import("std");
const builtin = @import("builtin");
const build_info = @import("build_info");
const Config = @import("config.zig");
const Alias = @import("alias.zig");
const Tui = @import("tui.zig");
const Check = @import("check.zig");
const Profile = @import("profile.zig");
const Screen = @import("screen.zig");
const output = @import("output.zig");

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
        printVersion();
    } else if (std.mem.eql(u8, command, "config")) {
        try handleConfig(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "alias")) {
        try handleAlias(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "tui")) {
        try Tui.run(allocator);
    } else if (std.mem.eql(u8, command, "status") or std.mem.eql(u8, command, "check")) {
        try Check.run(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "switch")) {
        try handleSwitch(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "node") or std.mem.eql(u8, command, "nodes")) {
        try handleNode(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "screen") or std.mem.eql(u8, command, "session")) {
        try Screen.run(allocator, args[2..]);
    } else if (Profile.looksLikeIndex(command)) {
        // proxy <序号> [命令...] —— 按 node list 的顺序选节点
        try handleIndexed(allocator, command, args[2..]);
    } else {
        // Execute command with proxy
        try execWithProxy(allocator, args[1..]);
    }
}

fn printVersion() void {
    output.print(
        "proxy version {s}\n" ++
            "\n" ++
            "提交哈希: {s}\n" ++
            "构建时间: {s}\n" ++
            "Zig 版本: {s}\n" ++
            "目标平台: {s}-{s} ({s})\n",
        .{
            build_info.version,
            build_info.commit,
            build_info.build_time,
            builtin.zig_version_string,
            @tagName(builtin.target.cpu.arch),
            @tagName(builtin.target.os.tag),
            @tagName(builtin.mode),
        },
    );
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
        \\  node                节点管理 (保存多套代理配置)
        \\  switch <节点>       一键切换代理节点 (支持序号)
        \\  tui                 启动 TUI 界面
        \\  status | check      检测代理连通性与延迟 (可选自定义测试地址)
        \\  screen [名称]       带代理的会话 (包装 screen/tmux, 支持分离重连)
        \\  <序号> [命令]       按 node list 的序号选节点: 带命令=只这条临时用, 不带=切换过去
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
        \\  proxy node save dev
        \\  proxy switch hk
        \\  proxy 1 curl https://google.com    # 用第 1 个节点跑，当前节点不变
        \\  proxy 2                            # 切换到第 2 个节点
        \\  proxy screen dev
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
        // 有激活节点时写透: 同步写回该节点
        try Profile.syncActive(allocator);
        var cfg = try Config.load(allocator);
        defer cfg.deinit();
        if (cfg.node.len > 0) {
            output.print("配置已保存: {s} = {s} (已同步到节点 {s})\n", .{ args[1], args[2], cfg.node });
        } else {
            output.print("配置已保存: {s} = {s}\n", .{ args[1], args[2] });
        }
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
        \\  protocol            代理协议 http/https/socks5/socks4 (默认: http)
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

fn handleSwitch(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try Profile.list(allocator);
        output.print("\n用法: proxy switch <节点名|序号>\n", .{});
        return;
    }

    const name = (try Profile.resolve(allocator, args[0])) orelse {
        output.print("错误: 节点不存在: {s}\n\n", .{args[0]});
        try Profile.list(allocator);
        return;
    };
    defer allocator.free(name);

    try switchAndReport(allocator, name);
}

/// 切到节点并回显生效的代理地址。
fn switchAndReport(allocator: std.mem.Allocator, name: []const u8) !void {
    try Profile.switchTo(allocator, name);

    var config = try Config.load(allocator);
    defer config.deinit();
    const url = try config.buildProxyUrl(allocator);
    defer allocator.free(url);
    output.print("✓ 已切换到节点 {s}: {s}\n", .{ name, url });
}

/// proxy <序号> [命令...] —— 按 node list 的顺序指定节点。
/// 不带命令 = 切换到该节点；带命令 = 只给这一条命令套用该节点，不改当前节点。
fn handleIndexed(allocator: std.mem.Allocator, token: []const u8, rest: []const []const u8) !void {
    const name = (try Profile.resolve(allocator, token)) orelse {
        const total = try Profile.count(allocator);
        if (total == 0) {
            output.print("错误: 暂无已保存的节点\n\n用 proxy node save <名称> 把当前配置保存为节点\n", .{});
        } else {
            output.print("错误: 节点序号 {s} 无效 (序号从 1 开始，当前共 {d} 个节点)\n\n", .{ token, total });
            try Profile.list(allocator);
        }
        return;
    };
    defer allocator.free(name);

    if (rest.len == 0) {
        try switchAndReport(allocator, name);
        return;
    }

    // 管理类子命令没有"临时节点"语义，明确拒绝，避免把临时配置写进磁盘
    if (isManageCommand(rest[0])) {
        output.print(
            "错误: proxy <序号> 只用于带该节点执行命令，不支持 {s} 子命令\n" ++
                "用法: proxy {s} <命令> [参数...]   先 proxy switch {s} 再管理\n",
            .{ rest[0], token, token },
        );
        return;
    }

    // 临时套用该节点配置: 只在本进程生效，Config.save 期间被禁写
    var node_config = try Profile.loadNode(allocator, name);
    defer {
        Config.clearEphemeral();
        node_config.deinit();
    }
    Config.setEphemeral(node_config);

    if (std.mem.eql(u8, rest[0], "status") or std.mem.eql(u8, rest[0], "check")) {
        try Check.run(allocator, rest[1..]);
    } else if (std.mem.eql(u8, rest[0], "screen") or std.mem.eql(u8, rest[0], "session")) {
        try Screen.run(allocator, rest[1..]);
    } else {
        try execWithProxy(allocator, rest);
    }
}

/// 会写配置文件的自有子命令，不能在临时节点下运行。
fn isManageCommand(name: []const u8) bool {
    const manage = [_][]const u8{ "config", "alias", "node", "nodes", "switch", "tui" };
    for (manage) |m| {
        if (std.mem.eql(u8, name, m)) return true;
    }
    return false;
}

fn handleNode(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try Profile.list(allocator);
        return;
    }

    const subcommand = args[0];

    if (std.mem.eql(u8, subcommand, "-h") or std.mem.eql(u8, subcommand, "--help")) {
        printNodeHelp();
    } else if (std.mem.eql(u8, subcommand, "save") or std.mem.eql(u8, subcommand, "add")) {
        if (args.len < 2) {
            output.print("错误: 需要提供节点名\n用法: proxy node save <名称>\n", .{});
            return;
        }
        try Profile.saveCurrent(allocator, args[1]);
        output.print("✓ 当前配置已保存为节点: {s}\n", .{args[1]});
    } else if (std.mem.eql(u8, subcommand, "remove") or std.mem.eql(u8, subcommand, "rm")) {
        if (args.len < 2) {
            output.print("错误: 需要提供节点名\n用法: proxy node remove <名称|序号>\n", .{});
            return;
        }
        const name = (try Profile.resolve(allocator, args[1])) orelse {
            output.print("错误: 节点不存在: {s}\n", .{args[1]});
            return;
        };
        defer allocator.free(name);
        try Profile.remove(allocator, name);
        output.print("✓ 节点已删除: {s}\n", .{name});
    } else if (std.mem.eql(u8, subcommand, "rename") or std.mem.eql(u8, subcommand, "mv")) {
        if (args.len < 3) {
            output.print("错误: 需要提供旧名与新名\n用法: proxy node rename <旧名|序号> <新名>\n", .{});
            return;
        }
        // 只解析旧名的序号，新名一律按字面量处理
        const old_name = (try Profile.resolve(allocator, args[1])) orelse {
            output.print("错误: 节点不存在: {s}\n", .{args[1]});
            return;
        };
        defer allocator.free(old_name);
        Profile.rename(allocator, old_name, args[2]) catch |err| {
            switch (err) {
                error.NodeNotFound => output.print("错误: 节点不存在: {s}\n", .{old_name}),
                error.NameExists => output.print("错误: 已存在同名节点: {s}\n", .{args[2]}),
                else => return err,
            }
            return;
        };
        output.print("✓ 节点已重命名: {s} → {s}\n", .{ old_name, args[2] });
    } else if (std.mem.eql(u8, subcommand, "unlink") or std.mem.eql(u8, subcommand, "detach")) {
        if (try Profile.unlink(allocator)) |old| {
            defer allocator.free(old);
            output.print("✓ 已脱离节点 {s}，之后 config set 不再写回该节点\n", .{old});
        } else {
            output.print("当前未激活任何节点，config set 只改当前配置\n", .{});
        }
    } else if (std.mem.eql(u8, subcommand, "list")) {
        try Profile.list(allocator);
    } else {
        output.print("未知的子命令: {s}\n", .{subcommand});
        printNodeHelp();
    }
}

fn printNodeHelp() void {
    const help =
        \\proxy node - 节点管理 (保存多套代理配置，一键切换)
        \\
        \\用法:
        \\  proxy node <子命令> [参数...]
        \\
        \\子命令:
        \\  save <名称>            把当前配置保存为节点 (同名覆盖)
        \\  rename <旧|序号> <新>  重命名节点
        \\  remove <名称|序号>     删除节点
        \\  unlink                 脱离当前节点 (之后 config set 不再写回节点)
        \\  list                   列出所有节点 (proxy node 不带参数同效)
        \\
        \\说明:
        \\  切换到节点后，proxy config set 会直接同步写回该节点
        \\  所以要另起一个配置不同的新节点，先 proxy node unlink 再改配置
        \\  节点名可用 list 里的序号代替 (同名节点优先按名字匹配)
        \\
        \\切换节点:
        \\  proxy switch <名称|序号>
        \\  proxy <序号>                    同上
        \\  proxy <序号> <命令> [参数...]   只让这条命令走该节点，不改当前节点
        \\
        \\示例:
        \\  proxy config set host 127.0.0.1 && proxy config set port 7890
        \\  proxy node save dev             # 本地开发代理
        \\  proxy node unlink               # 脱离 dev，下面的改动不会写回 dev
        \\  proxy config set host 10.1.0.8 && proxy node save company
        \\  proxy switch dev                # 一键切回
        \\  proxy 3 npm install             # 临时用第 3 个节点装包
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

    try Config.putProxyEnv(&env_map, proxy_url);

    // Execute command
    var child = std.process.Child.init(resolved_args, allocator);
    child.env_map = &env_map;
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = try child.spawnAndWait();
    std.process.exit(term.Exited);
}

test {
    _ = Tui;
    _ = Check;
    _ = Config;
    _ = Profile;
    _ = Screen;
}
