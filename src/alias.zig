const std = @import("std");
const builtin = @import("builtin");
const output = @import("output.zig");
const Storage = @import("storage.zig");

pub const Platform = enum {
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

fn loadAliases(allocator: std.mem.Allocator) !std.json.Parsed(std.json.Value) {
    const parsed = try Storage.loadObject(allocator, "aliases.json");
    errdefer parsed.deinit();
    var platforms = parsed.value.object.iterator();
    while (platforms.next()) |platform| {
        if (platform.value_ptr.* != .object) return error.CorruptAliases;
        var aliases = platform.value_ptr.object.iterator();
        while (aliases.next()) |entry| {
            if (entry.value_ptr.* != .string) return error.CorruptAliases;
        }
    }
    return parsed;
}

fn saveAliases(aliases: std.json.Value) !void {
    try Storage.save(std.heap.page_allocator, "aliases.json", aliases);
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
            _ = platform_value.object.orderedRemove(alias_name);
        }
    }

    // Save
    try saveAliases(parsed.value);
    try updateSavedOrder(allocator, .{ .platform = platform_str, .name = alias_name }, null);
}

/// 单条别名记录，字段由 getAll 复制，调用方用 freeEntries 释放。
pub const Entry = struct {
    platform: []const u8,
    name: []const u8,
    command: []const u8,
};

pub const Identity = struct { platform: []const u8, name: []const u8 };

/// Create or edit an alias without silently overwriting a different entry.
/// Renaming or moving platforms is persisted in a single file replacement.
pub fn storeEntry(allocator: std.mem.Allocator, entry: Entry, original: ?Identity) !void {
    _ = Platform.fromString(entry.platform) orelse return error.InvalidPlatform;
    var parsed = try loadAliases(allocator);
    defer parsed.deinit();
    var same_identity = false;
    if (original) |old| {
        const source = parsed.value.object.get(old.platform) orelse return error.AliasNotFound;
        if (!source.object.contains(old.name)) return error.AliasNotFound;
        same_identity = std.mem.eql(u8, old.platform, entry.platform) and std.mem.eql(u8, old.name, entry.name);
    }
    if (parsed.value.object.get(entry.platform)) |target| {
        if (target.object.contains(entry.name) and !same_identity) return error.NameExists;
    }
    const target = try parsed.value.object.getOrPut(entry.platform);
    if (!target.found_existing) {
        target.value_ptr.* = .{ .object = std.json.ObjectMap.init(parsed.arena.allocator()) };
    }
    if (original) |old| {
        if (std.mem.eql(u8, old.platform, entry.platform)) {
            try Storage.replaceKey(parsed.arena.allocator(), &target.value_ptr.object, old.name, entry.name, .{ .string = entry.command });
        } else {
            _ = parsed.value.object.getPtr(old.platform).?.object.orderedRemove(old.name);
            try target.value_ptr.object.put(entry.name, .{ .string = entry.command });
        }
    } else {
        try target.value_ptr.object.put(entry.name, .{ .string = entry.command });
    }
    try saveAliases(parsed.value);
    if (original) |old| {
        if (!same_identity) try updateSavedOrder(allocator, old, .{ .platform = entry.platform, .name = entry.name });
    }
}

pub fn removeExisting(allocator: std.mem.Allocator, identity: Identity) !void {
    var parsed = try loadAliases(allocator);
    defer parsed.deinit();
    const platform = parsed.value.object.getPtr(identity.platform) orelse return error.AliasNotFound;
    if (!platform.object.orderedRemove(identity.name)) return error.AliasNotFound;
    try saveAliases(parsed.value);
    try updateSavedOrder(allocator, identity, null);
}

fn sameIdentity(a: Identity, b: Identity) bool {
    return std.mem.eql(u8, a.platform, b.platform) and std.mem.eql(u8, a.name, b.name);
}

fn orderIdentity(value: std.json.Value) !Identity {
    if (value != .object) return error.InvalidStoredData;
    const platform = value.object.get("platform") orelse return error.InvalidStoredData;
    const name = value.object.get("name") orelse return error.InvalidStoredData;
    if (platform != .string or name != .string) return error.InvalidStoredData;
    return .{ .platform = platform.string, .name = name.string };
}

/// The original platform-grouped aliases.json remains compatible with the CLI.
/// A separate order list can interleave aliases from different platforms.
fn applySavedOrder(allocator: std.mem.Allocator, entries: []Entry) !void {
    const parsed = try Storage.loadObject(allocator, "order.json");
    defer parsed.deinit();
    const order = parsed.value.object.get("aliases") orelse return;
    if (order != .array) return error.InvalidStoredData;
    const ordered = try allocator.alloc(Entry, entries.len);
    defer allocator.free(ordered);
    const used = try allocator.alloc(bool, entries.len);
    defer allocator.free(used);
    @memset(used, false);
    var next: usize = 0;
    for (order.array.items) |value| {
        const identity = try orderIdentity(value);
        for (entries, 0..) |entry, index| {
            if (!used[index] and sameIdentity(identity, .{ .platform = entry.platform, .name = entry.name })) {
                ordered[next] = entry;
                next += 1;
                used[index] = true;
                break;
            }
        }
    }
    for (entries, 0..) |entry, index| {
        if (!used[index]) {
            ordered[next] = entry;
            next += 1;
        }
    }
    @memcpy(entries, ordered);
}

fn updateSavedOrder(allocator: std.mem.Allocator, old: Identity, replacement: ?Identity) !void {
    var parsed = try Storage.loadObject(allocator, "order.json");
    defer parsed.deinit();
    const order = parsed.value.object.getPtr("aliases") orelse return;
    if (order.* != .array) return error.InvalidStoredData;
    var changed = false;
    var index: usize = 0;
    while (index < order.array.items.len) {
        const identity = try orderIdentity(order.array.items[index]);
        if (sameIdentity(identity, old)) {
            changed = true;
            if (replacement) |new| {
                var object = &order.array.items[index].object;
                try object.put("platform", .{ .string = new.platform });
                try object.put("name", .{ .string = new.name });
            } else {
                _ = order.array.orderedRemove(index);
                continue;
            }
        }
        index += 1;
    }
    if (changed) try Storage.save(allocator, "order.json", parsed.value);
}

pub fn reorder(allocator: std.mem.Allocator, identities: []const Identity) !void {
    const entries = try getAll(allocator);
    defer freeEntries(allocator, entries);
    if (identities.len != entries.len) return error.OrderChanged;
    const used = try allocator.alloc(bool, entries.len);
    defer allocator.free(used);
    @memset(used, false);
    var parsed = try Storage.loadObject(allocator, "order.json");
    defer parsed.deinit();
    var order = std.array_list.Managed(std.json.Value).init(parsed.arena.allocator());
    for (identities) |identity| {
        const index = for (entries, 0..) |entry, index| {
            if (sameIdentity(identity, .{ .platform = entry.platform, .name = entry.name })) break index;
        } else return error.OrderChanged;
        if (used[index]) return error.InvalidOrder;
        used[index] = true;
        var object = std.json.ObjectMap.init(parsed.arena.allocator());
        try object.put("platform", .{ .string = identity.platform });
        try object.put("name", .{ .string = identity.name });
        try order.append(.{ .object = object });
    }
    try parsed.value.object.put("aliases", .{ .array = order });
    try Storage.save(allocator, "order.json", parsed.value);
}

/// 读取全部别名为数组，供网页等程序化访问。
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

    try applySavedOrder(allocator, result.items);
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

    try writer.writeAll("Aliases:\n\n");

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
