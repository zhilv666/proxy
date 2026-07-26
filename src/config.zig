const std = @import("std");
const output = @import("output.zig");

pub const ConfigData = struct {
    host: []const u8,
    port: []const u8,
    protocol: []const u8,
    username: []const u8,
    password: []const u8,
    /// 当前激活的代理节点名 (proxy switch 设置)，手动改配置后清空
    node: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ConfigData {
        return .{
            .host = "",
            .port = "",
            .protocol = "",
            .username = "",
            .password = "",
            .node = "",
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ConfigData) void {
        if (self.host.len > 0) self.allocator.free(self.host);
        if (self.port.len > 0) self.allocator.free(self.port);
        if (self.protocol.len > 0) self.allocator.free(self.protocol);
        if (self.username.len > 0) self.allocator.free(self.username);
        if (self.password.len > 0) self.allocator.free(self.password);
        if (self.node.len > 0) self.allocator.free(self.node);
    }

    pub fn buildProxyUrl(self: *const ConfigData, allocator: std.mem.Allocator) ![]const u8 {
        const host = if (self.host.len > 0) self.host else "127.0.0.1";
        const port = if (self.port.len > 0) self.port else "7890";
        const protocol = if (self.protocol.len > 0) self.protocol else "http";

        if (self.username.len > 0 and self.password.len > 0) {
            const encoded_user = try urlEncode(allocator, self.username);
            defer allocator.free(encoded_user);
            const encoded_pass = try urlEncode(allocator, self.password);
            defer allocator.free(encoded_pass);

            return std.fmt.allocPrint(allocator, "{s}://{s}:{s}@{s}:{s}", .{
                protocol,
                encoded_user,
                encoded_pass,
                host,
                port,
            });
        } else {
            return std.fmt.allocPrint(allocator, "{s}://{s}:{s}", .{
                protocol,
                host,
                port,
            });
        }
    }
};

fn urlEncode(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result = std.ArrayList(u8){};
    errdefer result.deinit(allocator);

    for (input) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '.' or c == '~' or c == '_' or c == '-') {
            try result.append(allocator, c);
        } else {
            try result.writer(allocator).print("%{X:0>2}", .{c});
        }
    }

    return result.toOwnedSlice(allocator);
}

fn getConfigDir() ![]const u8 {
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "PROXY_HOME")) |home| {
        return home;
    } else |_| {
        const home = std.process.getEnvVarOwned(std.heap.page_allocator, "HOME") catch |err| {
            if (err == error.EnvironmentVariableNotFound) {
                return std.process.getEnvVarOwned(std.heap.page_allocator, "USERPROFILE") catch {
                    return error.NoHomeDirectory;
                };
            }
            return err;
        };
        defer std.heap.page_allocator.free(home);

        return std.fmt.allocPrint(std.heap.page_allocator, "{s}/.proxy", .{home});
    }
}

fn getConfigPath(allocator: std.mem.Allocator) ![]const u8 {
    const config_dir = try getConfigDir();
    defer std.heap.page_allocator.free(config_dir);

    return std.fmt.allocPrint(allocator, "{s}/config.json", .{config_dir});
}

pub fn load(allocator: std.mem.Allocator) !ConfigData {
    const config_path = try getConfigPath(allocator);
    defer allocator.free(config_path);

    var config = ConfigData.init(allocator);

    const file = std.fs.openFileAbsolute(config_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            // Return default config
            return config;
        }
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    if (root.get("host")) |host| {
        config.host = try allocator.dupe(u8, host.string);
    }
    if (root.get("port")) |port| {
        config.port = try allocator.dupe(u8, port.string);
    }
    if (root.get("protocol")) |protocol| {
        config.protocol = try allocator.dupe(u8, protocol.string);
    }
    if (root.get("username")) |username| {
        config.username = try allocator.dupe(u8, username.string);
    }
    if (root.get("password")) |password| {
        config.password = try allocator.dupe(u8, password.string);
    }
    if (root.get("node")) |node| {
        if (node == .string) config.node = try allocator.dupe(u8, node.string);
    }

    return config;
}

pub fn set(allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    // Load existing config
    var config = try load(allocator);
    defer config.deinit();

    // Update the field
    if (std.mem.eql(u8, key, "host")) {
        if (config.host.len > 0) allocator.free(config.host);
        config.host = try allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "port")) {
        if (config.port.len > 0) allocator.free(config.port);
        config.port = try allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "protocol")) {
        if (config.protocol.len > 0) allocator.free(config.protocol);
        config.protocol = try allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "username") or std.mem.eql(u8, key, "user")) {
        if (config.username.len > 0) allocator.free(config.username);
        config.username = try allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "password") or std.mem.eql(u8, key, "pass")) {
        if (config.password.len > 0) allocator.free(config.password);
        config.password = try allocator.dupe(u8, value);
    } else {
        return error.UnknownConfigKey;
    }

    // 手动改过配置后，当前内容不再对应已保存的节点，清除标记
    if (config.node.len > 0) {
        allocator.free(config.node);
        config.node = "";
    }

    // Save config
    try save(&config);
}

/// 整体写入配置 (供节点切换等使用)。
pub fn store(config: *const ConfigData) !void {
    try save(config);
}

pub fn get(allocator: std.mem.Allocator, key: []const u8) !?[]const u8 {
    var config = try load(allocator);
    defer config.deinit();

    if (std.mem.eql(u8, key, "host")) {
        if (config.host.len > 0) return try allocator.dupe(u8, config.host);
    } else if (std.mem.eql(u8, key, "port")) {
        if (config.port.len > 0) return try allocator.dupe(u8, config.port);
    } else if (std.mem.eql(u8, key, "protocol")) {
        if (config.protocol.len > 0) return try allocator.dupe(u8, config.protocol);
    } else if (std.mem.eql(u8, key, "username") or std.mem.eql(u8, key, "user")) {
        if (config.username.len > 0) return try allocator.dupe(u8, config.username);
    } else if (std.mem.eql(u8, key, "password") or std.mem.eql(u8, key, "pass")) {
        if (config.password.len > 0) return try allocator.dupe(u8, config.password);
    }

    return null;
}

pub fn list(allocator: std.mem.Allocator) !void {
    var config = try load(allocator);
    defer config.deinit();

    const writer = try output.getWriter();

    try writer.writeAll("当前配置:\n");
    try writer.print("  host     = {s}\n", .{if (config.host.len > 0) config.host else "127.0.0.1 (默认)"});
    try writer.print("  port     = {s}\n", .{if (config.port.len > 0) config.port else "7890 (默认)"});
    try writer.print("  protocol = {s}\n", .{if (config.protocol.len > 0) config.protocol else "http (默认)"});
    try writer.print("  username = {s}\n", .{if (config.username.len > 0) config.username else "(未设置)"});
    try writer.print("  password = {s}\n", .{if (config.password.len > 0) "***" else "(未设置)"});
}

fn save(config: *const ConfigData) !void {
    const allocator = std.heap.page_allocator;

    const config_dir = try getConfigDir();
    defer allocator.free(config_dir);

    // Create directory if not exists
    std.fs.makeDirAbsolute(config_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const config_path = try std.fmt.allocPrint(allocator, "{s}/config.json", .{config_dir});
    defer allocator.free(config_path);

    // Build JSON
    var buffer = std.ArrayList(u8){};
    defer buffer.deinit(allocator);

    const writer = buffer.writer(allocator);
    try writer.writeAll("{\n");
    try writeField(writer, "host", config.host, true);
    try writeField(writer, "port", config.port, true);
    try writeField(writer, "protocol", config.protocol, true);
    try writeField(writer, "username", config.username, true);
    try writeField(writer, "password", config.password, true);
    try writeField(writer, "node", config.node, false);
    try writer.writeAll("}\n");

    // Write to file
    const file = try std.fs.createFileAbsolute(config_path, .{});
    defer file.close();

    try file.writeAll(buffer.items);
}

fn writeField(writer: anytype, key: []const u8, value: []const u8, comma: bool) !void {
    try writer.print("  \"{s}\": ", .{key});
    try writeJsonString(writer, value);
    try writer.writeAll(if (comma) ",\n" else "\n");
}

/// 写出带转义的 JSON 字符串，密码等值里的引号/反斜杠不会写坏配置文件。
pub fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

test "writeJsonString 转义引号反斜杠与控制字符" {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    try writeJsonString(buf.writer(std.testing.allocator), "a\"b\\c\n中");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\n中\"", buf.items);
}
