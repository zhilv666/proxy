//! Shared JSON storage for the CLI and local web manager.
const std = @import("std");

pub fn directory(allocator: std.mem.Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "PROXY_HOME")) |dir| {
        if (dir.len > 0) return dir;
        allocator.free(dir);
    } else |err| {
        if (err != error.EnvironmentVariableNotFound) return err;
    }

    const home_dir = std.process.getEnvVarOwned(allocator, "HOME") catch |err| blk: {
        if (err != error.EnvironmentVariableNotFound) return err;
        break :blk try std.process.getEnvVarOwned(allocator, "USERPROFILE");
    };
    defer allocator.free(home_dir);
    return std.fs.path.join(allocator, &.{ home_dir, ".proxy" });
}

fn path(allocator: std.mem.Allocator, filename: []const u8) ![]const u8 {
    const dir = try directory(allocator);
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, filename });
}

pub fn loadObject(allocator: std.mem.Allocator, filename: []const u8) !std.json.Parsed(std.json.Value) {
    const filename_path = try path(allocator, filename);
    defer allocator.free(filename_path);
    const file = std.fs.cwd().openFile(filename_path, .{}) catch |err| {
        if (err == error.FileNotFound) return std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
        return err;
    };
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    // Parsed strings must outlive content, including strings needing no escapes.
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidStoredData;
    return parsed;
}

pub fn save(allocator: std.mem.Allocator, filename: []const u8, value: anytype) !void {
    const content = try std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 });
    defer allocator.free(content);
    const filename_path = try path(allocator, filename);
    defer allocator.free(filename_path);
    var buffer: [4096]u8 = undefined;
    var file = try std.fs.cwd().atomicFile(filename_path, .{
        .make_path = true,
        .write_buffer = &buffer,
        .mode = 0o600,
    });
    defer file.deinit();
    try file.file_writer.interface.writeAll(content);
    try file.file_writer.interface.writeByte('\n');
    try file.finish();
}

/// Replace an object key while retaining its position in user-defined order.
pub fn replaceKey(allocator: std.mem.Allocator, object: *std.json.ObjectMap, old: []const u8, new: []const u8, value: std.json.Value) !void {
    if (std.mem.eql(u8, old, new)) return object.put(new, value);
    var replacement = std.json.ObjectMap.init(allocator);
    errdefer replacement.deinit();
    var entries = object.iterator();
    while (entries.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, old)) {
            try replacement.put(new, value);
        } else {
            try replacement.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }
    object.deinit();
    object.* = replacement;
}
