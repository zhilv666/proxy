//! 代理节点管理: 把多套代理配置存为命名节点，proxy switch 一键切换。
//! 存储于 $PROXY_HOME/profiles.json，格式: { "节点名": {host, port, protocol, username, password} }
const std = @import("std");
const Config = @import("config.zig");
const output = @import("output.zig");

const node_fields = [_][]const u8{ "host", "port", "protocol", "username", "password" };

fn getProfilePath(allocator: std.mem.Allocator) ![]const u8 {
    const config_dir = blk: {
        if (std.process.getEnvVarOwned(allocator, "PROXY_HOME")) |home| {
            break :blk home;
        } else |_| {
            const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| {
                if (err == error.EnvironmentVariableNotFound) {
                    const userprofile = try std.process.getEnvVarOwned(allocator, "USERPROFILE");
                    defer allocator.free(userprofile);
                    break :blk try std.fmt.allocPrint(allocator, "{s}/.proxy", .{userprofile});
                }
                return err;
            };
            defer allocator.free(home);
            break :blk try std.fmt.allocPrint(allocator, "{s}/.proxy", .{home});
        }
    };
    defer allocator.free(config_dir);

    return std.fmt.allocPrint(allocator, "{s}/profiles.json", .{config_dir});
}

fn loadProfiles(allocator: std.mem.Allocator) !std.json.Parsed(std.json.Value) {
    const path = try getProfilePath(allocator);
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            return try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
        }
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    return try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
}

fn saveProfiles(root: std.json.Value) !void {
    const allocator = std.heap.page_allocator;

    const path = try getProfilePath(allocator);
    defer allocator.free(path);

    if (std.fs.path.dirname(path)) |dir| {
        std.fs.makeDirAbsolute(dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
    }

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    try writer.writeAll("{\n");
    if (root == .object) {
        const keys = root.object.keys();
        for (keys, 0..) |key, i| {
            const value = root.object.get(key).?;
            if (value != .object) continue;
            try writer.writeAll("  ");
            try Config.writeJsonString(writer, key);
            try writer.writeAll(": {\n");
            for (node_fields, 0..) |field, fi| {
                const fv = strField(value.object, field, "");
                try writer.print("    \"{s}\": ", .{field});
                try Config.writeJsonString(writer, fv);
                try writer.writeAll(if (fi + 1 < node_fields.len) ",\n" else "\n");
            }
            try writer.writeAll(if (i + 1 < keys.len) "  },\n" else "  }\n");
        }
    }
    try writer.writeAll("}\n");

    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(buf.items);
}

fn strField(obj: std.json.ObjectMap, key: []const u8, default: []const u8) []const u8 {
    const value = obj.get(key) orelse return default;
    if (value != .string or value.string.len == 0) return default;
    return value.string;
}

/// 把当前配置保存为节点，并标记为当前节点。
pub fn saveCurrent(allocator: std.mem.Allocator, name: []const u8) !void {
    if (name.len == 0) return error.InvalidNodeName;

    var config = try Config.load(allocator);
    defer config.deinit();

    var parsed = try loadProfiles(allocator);
    defer parsed.deinit();
    if (parsed.value != .object) return error.CorruptProfiles;

    // 新对象放进 parsed 的 arena，随 parsed.deinit 一起释放
    const arena = parsed.arena.allocator();
    var obj = std.json.ObjectMap.init(arena);
    try obj.put("host", .{ .string = try arena.dupe(u8, config.host) });
    try obj.put("port", .{ .string = try arena.dupe(u8, config.port) });
    try obj.put("protocol", .{ .string = try arena.dupe(u8, config.protocol) });
    try obj.put("username", .{ .string = try arena.dupe(u8, config.username) });
    try obj.put("password", .{ .string = try arena.dupe(u8, config.password) });
    try parsed.value.object.put(try arena.dupe(u8, name), .{ .object = obj });

    try saveProfiles(parsed.value);

    // 当前配置即该节点
    if (config.node.len > 0) allocator.free(config.node);
    config.node = try allocator.dupe(u8, name);
    try Config.store(&config);
}

/// 切换到指定节点: 整体覆盖当前配置。
pub fn switchTo(allocator: std.mem.Allocator, name: []const u8) !void {
    var parsed = try loadProfiles(allocator);
    defer parsed.deinit();
    if (parsed.value != .object) return error.NodeNotFound;

    const entry = parsed.value.object.get(name) orelse return error.NodeNotFound;
    if (entry != .object) return error.NodeNotFound;

    var config = Config.ConfigData.init(allocator);
    defer config.deinit();
    config.host = try allocator.dupe(u8, strField(entry.object, "host", ""));
    config.port = try allocator.dupe(u8, strField(entry.object, "port", ""));
    config.protocol = try allocator.dupe(u8, strField(entry.object, "protocol", ""));
    config.username = try allocator.dupe(u8, strField(entry.object, "username", ""));
    config.password = try allocator.dupe(u8, strField(entry.object, "password", ""));
    config.node = try allocator.dupe(u8, name);

    try Config.store(&config);
}

/// 删除节点；若删除的是当前节点则清除标记。
pub fn remove(allocator: std.mem.Allocator, name: []const u8) !void {
    var parsed = try loadProfiles(allocator);
    defer parsed.deinit();
    if (parsed.value != .object) return error.NodeNotFound;
    if (!parsed.value.object.swapRemove(name)) return error.NodeNotFound;

    try saveProfiles(parsed.value);

    var config = try Config.load(allocator);
    defer config.deinit();
    if (std.mem.eql(u8, config.node, name)) {
        allocator.free(config.node);
        config.node = "";
        try Config.store(&config);
    }
}

/// 列出所有节点，标记当前激活的。
pub fn list(allocator: std.mem.Allocator) !void {
    var parsed = try loadProfiles(allocator);
    defer parsed.deinit();

    var config = try Config.load(allocator);
    defer config.deinit();

    const writer = try output.getWriter();

    if (parsed.value != .object or parsed.value.object.count() == 0) {
        try writer.writeAll("暂无已保存的节点\n\n用 proxy node save <名称> 把当前配置保存为节点\n");
        return;
    }

    try writer.writeAll("节点列表:\n\n");
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        const name = entry.key_ptr.*;
        const obj = entry.value_ptr.object;
        const active = std.mem.eql(u8, config.node, name);

        try writer.print("  {s} {s}", .{ if (active) "▸" else " ", name });
        // 名称列对齐 (按字节，节点名一般为 ASCII)
        var pad = if (name.len < 12) 12 - name.len else 1;
        while (pad > 0) : (pad -= 1) try writer.writeAll(" ");

        const username = strField(obj, "username", "");
        if (username.len > 0) {
            try writer.print("{s}://{s}@{s}:{s}", .{
                strField(obj, "protocol", "http"),
                username,
                strField(obj, "host", "127.0.0.1"),
                strField(obj, "port", "7890"),
            });
        } else {
            try writer.print("{s}://{s}:{s}", .{
                strField(obj, "protocol", "http"),
                strField(obj, "host", "127.0.0.1"),
                strField(obj, "port", "7890"),
            });
        }
        try writer.print("{s}\n", .{if (active) "   ← 当前" else ""});
    }
}
