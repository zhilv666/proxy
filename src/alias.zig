const std = @import("std");
const builtin = @import("builtin");
const output = @import("output.zig");

const Platform = enum {
    windows,
    linux,
    macos,
    all,

    pub fn fromString(s: []const u8) ?Platform {
        if (std.mem.eql(u8, s, "windows")) return .windows;
        if (std.mem.eql(u8, s, "linux")) return .linux;
        if (std.mem.eql(u8, s, "macos")) return .macos;
        if (std.mem.eql(u8, s, "all")) return .all;
        return null;
    }

    pub fn toString(self: Platform) []const u8 {
        return switch (self) {
            .windows => "windows",
            .linux => "linux",
            .macos => "macos",
            .all => "all",
        };
    }

    pub fn current() Platform {
        return switch (builtin.os.tag) {
            .windows => .windows,
            .linux => .linux,
            .macos => .macos,
            else => .linux,
        };
    }
};

const AliasEntry = struct {
    platform: Platform,
    alias: []const u8,
    command: []const u8,
};

fn getAliasPath(allocator: std.mem.Allocator) ![]const u8 {
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

    return std.fmt.allocPrint(allocator, "{s}/aliases.json", .{config_dir});
}

fn loadAliases(allocator: std.mem.Allocator) !std.json.Parsed(std.json.Value) {
    const alias_path = try getAliasPath(allocator);
    defer allocator.free(alias_path);

    const file = std.fs.openFileAbsolute(alias_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            // Return empty JSON object
            const empty = "{}";
            return try std.json.parseFromSlice(std.json.Value, allocator, empty, .{});
        }
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    return try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
}

fn saveAliases(aliases: std.json.Value) !void {
    const allocator = std.heap.page_allocator;

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

    // Create directory if not exists
    std.fs.makeDirAbsolute(config_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const alias_path = try std.fmt.allocPrint(allocator, "{s}/aliases.json", .{config_dir});
    defer allocator.free(alias_path);

    // Write to file
    const file = try std.fs.createFileAbsolute(alias_path, .{});
    defer file.close();

    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);

    const writer = buf.writer(allocator);

    // Write object format
    try writer.writeAll("{\n");

    if (aliases == .object) {
        const keys = aliases.object.keys();
        var first = true;

        for (keys) |key| {
            if (!first) try writer.writeAll(",\n");
            first = false;

            try writer.print("  \"{s}\": {{\n", .{key});

            const platform_value = aliases.object.get(key).?;
            if (platform_value == .object) {
                const alias_keys = platform_value.object.keys();
                var first_alias = true;

                for (alias_keys) |alias_key| {
                    if (!first_alias) try writer.writeAll(",\n");
                    first_alias = false;

                    const cmd_value = platform_value.object.get(alias_key).?;
                    if (cmd_value == .string) {
                        try writer.print("    \"{s}\": \"{s}\"", .{ alias_key, cmd_value.string });
                    }
                }
                try writer.writeAll("\n");
            }

            try writer.writeAll("  }");
        }

        if (!first) try writer.writeAll("\n");
    }

    try writer.writeAll("}\n");

    try file.writeAll(buf.items);
}

pub fn add(allocator: std.mem.Allocator, platform_str: []const u8, alias_name: []const u8, command: []const u8) !void {
    const platform = Platform.fromString(platform_str) orelse return error.InvalidPlatform;

    var parsed = try loadAliases(allocator);
    defer parsed.deinit();
    if (parsed.value != .object) return error.CorruptAliases;

    const platform_key = platform.toString();

    // Get or create platform object
    const gop = try parsed.value.object.getOrPut(platform_key);
    if (!gop.found_existing) {
        // 挂进 parsed 的 arena，随 parsed.deinit 一起释放 (用 gpa 建会漏)
        gop.value_ptr.* = .{ .object = std.json.ObjectMap.init(parsed.arena.allocator()) };
    }

    // Add alias
    const command_value = std.json.Value{ .string = command };
    try gop.value_ptr.object.put(alias_name, command_value);

    // Save
    try saveAliases(parsed.value);
}

pub fn remove(allocator: std.mem.Allocator, platform_str: []const u8, alias_name: []const u8) !void {
    const platform = Platform.fromString(platform_str) orelse return error.InvalidPlatform;

    var parsed = try loadAliases(allocator);
    defer parsed.deinit();
    if (parsed.value != .object) return error.CorruptAliases;

    const platform_key = platform.toString();

    if (parsed.value.object.getPtr(platform_key)) |platform_value| {
        if (platform_value.* == .object) {
            _ = platform_value.object.swapRemove(alias_name);
        }
    }

    // Save
    try saveAliases(parsed.value);
}

/// 单条别名记录，字段由 getAll 复制，调用方用 freeEntries 释放。
pub const Entry = struct {
    platform: []const u8,
    name: []const u8,
    command: []const u8,
};

/// 读取全部别名为数组，供 TUI 等程序化访问。
pub fn getAll(allocator: std.mem.Allocator) ![]Entry {
    const parsed = try loadAliases(allocator);
    defer parsed.deinit();

    var result: std.ArrayList(Entry) = .{};
    errdefer {
        for (result.items) |e| {
            allocator.free(e.platform);
            allocator.free(e.name);
            allocator.free(e.command);
        }
        result.deinit(allocator);
    }

    if (parsed.value != .object) return result.toOwnedSlice(allocator);

    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        var alias_it = entry.value_ptr.object.iterator();
        while (alias_it.next()) |alias_entry| {
            if (alias_entry.value_ptr.* != .string) continue;
            const platform = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(platform);
            const name = try allocator.dupe(u8, alias_entry.key_ptr.*);
            errdefer allocator.free(name);
            const command = try allocator.dupe(u8, alias_entry.value_ptr.string);
            errdefer allocator.free(command);
            try result.append(allocator, .{
                .platform = platform,
                .name = name,
                .command = command,
            });
        }
    }

    return result.toOwnedSlice(allocator);
}

pub fn freeEntries(allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |e| {
        allocator.free(e.platform);
        allocator.free(e.name);
        allocator.free(e.command);
    }
    allocator.free(entries);
}

pub fn list(allocator: std.mem.Allocator) !void {
    const parsed = try loadAliases(allocator);
    defer parsed.deinit();

    const root = parsed.value.object;
    const writer = try output.getWriter();

    try writer.writeAll("别名列表:\n\n");

    var it = root.iterator();
    while (it.next()) |entry| {
        const platform_name = entry.key_ptr.*;
        const aliases = entry.value_ptr.object;

        if (aliases.count() > 0) {
            try writer.print("[{s}]\n", .{platform_name});

            var alias_it = aliases.iterator();
            while (alias_it.next()) |alias_entry| {
                try writer.print("  {s} -> {s}\n", .{ alias_entry.key_ptr.*, alias_entry.value_ptr.string });
            }
            try writer.writeAll("\n");
        }
    }
}

pub fn resolve(allocator: std.mem.Allocator, args: []const []const u8) ![][]const u8 {
    if (args.len == 0) return try allocator.dupe([]const u8, args);

    const parsed = try loadAliases(allocator);
    defer parsed.deinit();

    const root = parsed.value.object;
    const current_platform = Platform.current();

    // Try current platform first
    if (root.get(current_platform.toString())) |platform_value| {
        if (platform_value.object.get(args[0])) |command_value| {
            return try expandAlias(allocator, command_value.string, args[1..]);
        }
    }

    // Try "all" platform
    if (root.get("all")) |platform_value| {
        if (platform_value.object.get(args[0])) |command_value| {
            return try expandAlias(allocator, command_value.string, args[1..]);
        }
    }

    // No alias found, return original args
    var result = try allocator.alloc([]const u8, args.len);
    for (args, 0..) |arg, i| {
        result[i] = try allocator.dupe(u8, arg);
    }
    return result;
}

fn expandAlias(allocator: std.mem.Allocator, command: []const u8, extra_args: []const []const u8) ![][]const u8 {
    // Parse command into parts
    var parts: std.ArrayList([]const u8) = .{};
    defer parts.deinit(allocator);

    var it = std.mem.tokenizeAny(u8, command, " \t");
    while (it.next()) |part| {
        try parts.append(allocator, try allocator.dupe(u8, part));
    }

    // Add extra args
    for (extra_args) |arg| {
        try parts.append(allocator, try allocator.dupe(u8, arg));
    }

    return parts.toOwnedSlice(allocator);
}
