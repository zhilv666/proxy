const std = @import("std");
const builtin = @import("builtin");
const build_info = @import("build_info");
const Config = @import("config.zig");
const Alias = @import("alias.zig");
const Check = @import("check.zig");
const Profile = @import("profile.zig");
const Enter = @import("enter.zig");
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
    } else if (std.mem.eql(u8, command, "status") or std.mem.eql(u8, command, "check")) {
        try Check.run(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "switch")) {
        try handleSwitch(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "node") or std.mem.eql(u8, command, "nodes")) {
        try handleNode(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "on")) {
        // proxy on —— 进入当前节点的代理子 shell,命令走代理,exit 返回原环境
        try Enter.run(allocator);
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
            "commit: {s}\n" ++
            "build time: {s}\n" ++
            "Zig version: {s}\n" ++
            "target: {s}-{s} ({s})\n",
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
        \\proxy - cross-platform proxy CLI
        \\
        \\Usage:
        \\  proxy [command] [args...]
        \\
        \\Commands:
        \\  config              Manage config
        \\  alias               Manage aliases
        \\  node                Manage saved proxy nodes
        \\  switch <node>       Switch node (name or index)
        \\  status | check      Check proxy connectivity and latency
        \\  on                  Enter a proxied subshell for the current node (exit to leave)
        \\  <index> [command]   Pick node by list index: with command = run once via that node
        \\  <command> [args]    Run a command through the proxy
        \\
        \\Options:
        \\  -h, --help          Show help
        \\  -v, --version       Show version
        \\
        \\Examples:
        \\  proxy curl https://google.com
        \\  proxy ll
        \\  proxy config set host 127.0.0.1
        \\  proxy alias add windows ll "ls -l"
        \\  proxy node save dev
        \\  proxy switch hk
        \\  proxy on                           # enter a proxied subshell; exit to return
        \\  proxy 2 on                         # enter subshell via node 2 proxy
        \\  proxy 1 curl https://google.com    # run once via node 1, keep current node
        \\  proxy 2                            # switch to node 2
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
            output.print("error: key and value are required\nusage: proxy config set <key> <value>\n", .{});
            return;
        }
        try Config.set(allocator, args[1], args[2]);
        // 有激活节点时写透: 同步写回该节点
        try Profile.syncActive(allocator);
        var cfg = try Config.load(allocator);
        defer cfg.deinit();
        if (cfg.node.len > 0) {
            output.print("config saved: {s} = {s} (synced to node {s})\n", .{ args[1], args[2], cfg.node });
        } else {
            output.print("config saved: {s} = {s}\n", .{ args[1], args[2] });
        }
    } else if (std.mem.eql(u8, subcommand, "get")) {
        if (args.len < 2) {
            output.print("error: a key is required\nusage: proxy config get <key>\n", .{});
            return;
        }
        const value = try Config.get(allocator, args[1]);
        if (value) |v| {
            defer allocator.free(v);
            output.print("{s} = {s}\n", .{ args[1], v });
        } else {
            output.print("{s} is not set\n", .{args[1]});
        }
    } else if (std.mem.eql(u8, subcommand, "list")) {
        try Config.list(allocator);
    } else {
        output.print("unknown subcommand: {s}\n", .{subcommand});
        printConfigHelp();
    }
}

fn printConfigHelp() void {
    const help =
        \\ proxy config - manage configuration
        \\
        \\ Usage:
        \\   proxy config <subcommand> [args...]
        \\
        \\ Subcommands:
        \\   set <key> <value>   Set a config key
        \\   get <key>           Get a config value
        \\   list                Show all config
        \\
        \\ Keys:
        \\   host                Proxy host (default: 127.0.0.1)
        \\   port                Proxy port (default: 7890)
        \\   protocol            Proxy protocol http/https/socks5/socks4 (default: http)
        \\   username            Proxy username
        \\   password            Proxy password
        \\
        \\ Examples:
        \\   proxy config set host 127.0.0.1
        \\   proxy config set port 7890
        \\   proxy config set username myuser
        \\   proxy config list
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
            output.print("error: platform, alias and command are required\nusage: proxy alias add <platform> <alias> <command>\n", .{});
            return;
        }
        try Alias.add(allocator, args[1], args[2], args[3]);
        output.print("alias added: {s} ({s}) -> {s}\n", .{ args[2], args[1], args[3] });
    } else if (std.mem.eql(u8, subcommand, "remove")) {
        if (args.len < 3) {
            output.print("error: platform and alias are required\nusage: proxy alias remove <platform> <alias>\n", .{});
            return;
        }
        try Alias.remove(allocator, args[1], args[2]);
        output.print("alias removed: {s} ({s})\n", .{ args[2], args[1] });
    } else if (std.mem.eql(u8, subcommand, "list")) {
        try Alias.list(allocator);
    } else {
        output.print("unknown subcommand: {s}\n", .{subcommand});
        printAliasHelp();
    }
}

fn printAliasHelp() void {
    const help =
        \\ proxy alias - manage aliases
        \\
        \\ Usage:
        \\   proxy alias <subcommand> [args...]
        \\
        \\ Subcommands:
        \\   add <platform> <alias> <command>    Add an alias
        \\   remove <platform> <alias>           Remove an alias
        \\   list                                List all aliases
        \\
        \\ Platforms:
        \\   windows, linux, macos, all          all = every platform
        \\
        \\ Examples:
        \\   proxy alias add linux ll "ls -l"
        \\   proxy alias add windows ll "dir"
        \\   proxy alias add all gs "git status"
        \\   proxy alias remove linux ll
        \\   proxy alias list
    ;
    output.print("{s}", .{help});
}

fn handleSwitch(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try Profile.list(allocator);
        output.print("\nusage: proxy switch <node|index>\n", .{});
        return;
    }

    const name = (try Profile.resolve(allocator, args[0])) orelse {
        output.print("error: node not found: {s}\n\n", .{args[0]});
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
    output.print("switched to node {s}: {s}\n", .{ name, url });
}

/// proxy <序号> [命令...] —— 按 node list 的顺序指定节点。
/// 不带命令 = 切换到该节点；带命令 = 只给这一条命令套用该节点，不改当前节点。
fn handleIndexed(allocator: std.mem.Allocator, token: []const u8, rest: []const []const u8) !void {
    const name = (try Profile.resolve(allocator, token)) orelse {
        const total = try Profile.count(allocator);
        if (total == 0) {
            output.print("error: no saved nodes yet\n\nuse \"proxy node save <name>\" to save the current config as a node\n", .{});
        } else {
            output.print("error: invalid node index {s} (index starts at 1, {d} nodes total)\n\n", .{ token, total });
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
            "error: proxy <index> runs a command via that node only; unsupported here: {s}\n" ++
                "usage: proxy {s} <command> [args...]   use \"proxy switch {s}\" first to manage\n",
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
    } else if (std.mem.eql(u8, rest[0], "on")) {
        // proxy <序号> on —— 进入该节点的代理子 shell (期间 Config 临时为该节点)
        try Enter.run(allocator);
    } else {
        try execWithProxy(allocator, rest);
    }
}

/// 会写配置文件的自有子命令，不能在临时节点下运行。
fn isManageCommand(name: []const u8) bool {
    const manage = [_][]const u8{ "config", "alias", "node", "nodes", "switch" };
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
            output.print("error: a node name is required\nusage: proxy node save <name>\n", .{});
            return;
        }
        try Profile.saveCurrent(allocator, args[1]);
        output.print("current config saved as node: {s}\n", .{args[1]});
    } else if (std.mem.eql(u8, subcommand, "remove") or std.mem.eql(u8, subcommand, "rm")) {
        if (args.len < 2) {
            output.print("error: a node name is required\nusage: proxy node remove <name|index>\n", .{});
            return;
        }
        const name = (try Profile.resolve(allocator, args[1])) orelse {
            output.print("error: node not found: {s}\n", .{args[1]});
            return;
        };
        defer allocator.free(name);
        try Profile.remove(allocator, name);
        output.print("node removed: {s}\n", .{name});
    } else if (std.mem.eql(u8, subcommand, "rename") or std.mem.eql(u8, subcommand, "mv")) {
        if (args.len < 3) {
            output.print("error: old and new names are required\nusage: proxy node rename <old|index> <new>\n", .{});
            return;
        }
        // 只解析旧名的序号，新名一律按字面量处理
        const old_name = (try Profile.resolve(allocator, args[1])) orelse {
            output.print("error: node not found: {s}\n", .{args[1]});
            return;
        };
        defer allocator.free(old_name);
        Profile.rename(allocator, old_name, args[2]) catch |err| {
            switch (err) {
                error.NodeNotFound => output.print("error: node not found: {s}\n", .{old_name}),
                error.NameExists => output.print("error: a node with that name already exists: {s}\n", .{args[2]}),
                else => return err,
            }
            return;
        };
        output.print("node renamed: {s} -> {s}\n", .{ old_name, args[2] });
    } else if (std.mem.eql(u8, subcommand, "unlink") or std.mem.eql(u8, subcommand, "detach")) {
        if (try Profile.unlink(allocator)) |old| {
            defer allocator.free(old);
            output.print("detached from node {s}; config set will no longer write back to it\n", .{old});
        } else {
            output.print("no active node; config set only changes the current config\n", .{});
        }
    } else if (std.mem.eql(u8, subcommand, "list")) {
        try Profile.list(allocator);
    } else {
        output.print("unknown subcommand: {s}\n", .{subcommand});
        printNodeHelp();
    }
}

fn printNodeHelp() void {
    const help =
        \\ proxy node - manage saved proxy nodes
        \\
        \\ Usage:
        \\   proxy node <subcommand> [args...]
        \\
        \\ Subcommands:
        \\   save <name>            Save current config as a node (overwrite if exists)
        \\   rename <old|index> <new>  Rename a node
        \\   remove <name|index>    Remove a node
        \\   unlink                 Detach from current node (config set no longer writes back)
        \\   list                   List all nodes (proxy node with no args does the same)
        \\
        \\ Notes:
        \\   After switching to a node, proxy config set writes back to that node
        \\   To start a different node, proxy node unlink first, then change config
        \\   Indexes come from list; a name matching an index wins
        \\
        \\ Switching:
        \\   proxy switch <name|index>
        \\   proxy <index>                   same as above
        \\   proxy <index> <command> [...]   run once via that node without switching
        \\
        \\ Examples:
        \\   proxy config set host 127.0.0.1 && proxy config set port 7890
        \\   proxy node save dev             # local dev proxy
        \\   proxy node unlink               # stop writing back to dev
        \\   proxy config set host 10.1.0.8 && proxy node save company
        \\   proxy switch dev                # switch back
        \\   proxy 3 npm install             # run via node 3 for this command only
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
    _ = Check;
    _ = Config;
    _ = Profile;
    _ = Enter;
}
