//! Loopback-only HTTP configuration manager. Assets are embedded in the binary.
const std = @import("std");
const builtin = @import("builtin");
const build_info = @import("build_info");
const Config = @import("config.zig");
const Profile = @import("profile.zig");
const Alias = @import("alias.zig");
const output = @import("output.zig");

const max_headers = 16 * 1024;
const max_body = 64 * 1024;
const max_connections = 16;
const socket_timeout_ms: u32 = 5000;

const State = struct {
    port: u16,
    mutex: std.Thread.Mutex = .{},
    connections: std.atomic.Value(usize) = .init(0),
};

const Request = struct {
    method: std.http.Method,
    target: []const u8,
    body: []const u8,
};

const Response = struct {
    status: std.http.Status = .ok,
    content_type: []const u8 = "application/json; charset=utf-8",
    body: []const u8,
};

pub fn run(_: std.mem.Allocator, args: []const []const u8) !void {
    const port = parsePort(args) catch {
        output.print("error: use proxy serve [--port <0-65535>]\n", .{});
        return error.InvalidArguments;
    } orelse {
        output.print(
            \\proxy serve - manage proxy configuration in your browser
            \\
            \\Usage: proxy serve [--port <port>]
            \\
            \\Options:
            \\  -p, --port <port>  HTTP port (default: 8080; 0 chooses a free port)
            \\  -h, --help         Show help
            \\
            \\Listens on 127.0.0.1 only. Uses PROXY_HOME or ~/.proxy.
            \\Open the printed URL in your browser; press Ctrl+C to stop.
            \\
        , .{});
        return;
    };
    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    var server = address.listen(.{}) catch |err| {
        output.print("error: cannot listen on 127.0.0.1:{d}: {s}\n", .{ port, @errorName(err) });
        return err;
    };
    defer server.deinit();
    var state = State{ .port = server.listen_address.getPort() };
    output.print("Proxy web manager: http://127.0.0.1:{d}/\nPress Ctrl+C to stop.\n", .{state.port});

    while (true) {
        const connection = server.accept() catch |err| {
            output.print("serve: accept failed: {s}\n", .{@errorName(err)});
            std.Thread.sleep(100 * std.time.ns_per_ms);
            continue;
        };
        setTimeouts(connection.stream.handle);
        if (state.connections.fetchAdd(1, .monotonic) >= max_connections) {
            _ = state.connections.fetchSub(1, .monotonic);
            sendResponse(connection.stream, .{
                .status = .service_unavailable,
                .body = "{\"error\":\"连接过多，请稍后重试\"}",
            }, false) catch {};
            connection.stream.close();
            continue;
        }
        const thread = std.Thread.spawn(.{}, handleConnection, .{ &state, connection.stream }) catch |err| {
            connection.stream.close();
            _ = state.connections.fetchSub(1, .monotonic);
            output.print("serve: cannot start worker: {s}\n", .{@errorName(err)});
            continue;
        };
        thread.detach();
    }
}

fn parsePort(args: []const []const u8) !?u16 {
    if (args.len == 1 and (eql(args[0], "--help") or eql(args[0], "-h"))) return null;
    if (args.len == 0) return 8080;
    const value = if (args.len == 2 and (eql(args[0], "--port") or eql(args[0], "-p")))
        args[1]
    else if (args.len == 1 and std.mem.startsWith(u8, args[0], "--port="))
        args[0][7..]
    else
        return error.InvalidArguments;
    if (!Profile.looksLikeIndex(value)) return error.InvalidArguments;
    return std.fmt.parseInt(u16, value, 10) catch error.InvalidArguments;
}

fn handleConnection(state: *State, stream: std.net.Stream) void {
    defer closeConnection(stream);
    defer _ = state.connections.fetchSub(1, .monotonic);
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const request = readRequest(allocator, stream, state.port) catch |err| {
        const response = errorResponse(allocator, err) catch return;
        sendResponse(stream, response, false) catch {};
        return;
    };
    const response = route(state, allocator, request) catch |err| errorResponse(allocator, err) catch return;
    sendResponse(stream, response, request.method == .HEAD) catch {};
}

fn readRequest(allocator: std.mem.Allocator, stream: std.net.Stream, port: u16) !Request {
    const buffer = try allocator.alloc(u8, max_headers);
    var used: usize = 0;
    const head_end = while (true) {
        if (std.mem.indexOf(u8, buffer[0..used], "\r\n\r\n")) |end| break end + 4;
        if (used == buffer.len) return error.HeadersTooLarge;
        const n = try readSocket(stream, buffer[used..]);
        if (n == 0) return error.InvalidRequest;
        used += n;
    };
    const head = std.http.Server.Request.Head.parse(buffer[0..head_end]) catch return error.InvalidRequest;
    try validateHeaders(buffer[0..head_end], port, head.method);
    if (head.transfer_encoding != .none) return error.InvalidRequest;
    if (head.transfer_compression != .identity) return error.UnsupportedMediaType;
    const body_len = head.content_length orelse 0;
    if (body_len > max_body) return error.BodyTooLarge;
    if (head.expect != null) return error.ExpectationFailed;
    if (isMutation(head.method)) {
        const content_type = head.content_type orelse return error.UnsupportedMediaType;
        var parts = std.mem.splitScalar(u8, content_type, ';');
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, parts.first(), " \t"), "application/json")) {
            return error.UnsupportedMediaType;
        }
    }
    const body = try allocator.alloc(u8, @intCast(body_len));
    const buffered_len = @min(body.len, used - head_end);
    @memcpy(body[0..buffered_len], buffer[head_end..][0..buffered_len]);
    var received = buffered_len;
    while (received < body.len) {
        const n = try readSocket(stream, body[received..]);
        if (n == 0) return error.InvalidRequest;
        received += n;
    }
    const path_end = std.mem.indexOfScalar(u8, head.target, '?') orelse head.target.len;
    return .{ .method = head.method, .target = head.target[0..path_end], .body = body };
}

fn validateHeaders(bytes: []const u8, port: u16, method: std.http.Method) !void {
    var ip_buffer: [64]u8 = undefined;
    var local_buffer: [64]u8 = undefined;
    const ip_origin = try std.fmt.bufPrint(&ip_buffer, "http://127.0.0.1:{d}", .{port});
    const local_origin = try std.fmt.bufPrint(&local_buffer, "http://localhost:{d}", .{port});
    var host_count: usize = 0;
    var has_request_header = false;
    var headers = std.http.HeaderIterator.init(bytes);
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "host")) {
            host_count += 1;
            if (!std.ascii.eqlIgnoreCase(header.value, ip_origin[7..]) and
                !std.ascii.eqlIgnoreCase(header.value, local_origin[7..]) and
                !(port == 80 and (std.ascii.eqlIgnoreCase(header.value, "127.0.0.1") or std.ascii.eqlIgnoreCase(header.value, "localhost"))))
                return error.Forbidden;
        } else if (std.ascii.eqlIgnoreCase(header.name, "origin")) {
            if (!eql(header.value, ip_origin) and !eql(header.value, local_origin) and
                !(port == 80 and (eql(header.value, "http://127.0.0.1") or eql(header.value, "http://localhost"))))
                return error.Forbidden;
        } else if (std.ascii.eqlIgnoreCase(header.name, "x-proxy-request")) {
            has_request_header = eql(header.value, "1");
        }
    }
    // Host validation blocks DNS rebinding. The custom header and JSON content
    // type prevent cross-origin forms from changing local settings.
    if (host_count != 1) return error.Forbidden;
    if (isMutation(method) and !has_request_header) return error.Forbidden;
}

fn route(state: *State, allocator: std.mem.Allocator, request: Request) !Response {
    const path = request.target;
    const method = request.method;
    if (!std.mem.startsWith(u8, path, "/api/")) {
        if (method != .GET and method != .HEAD) return error.MethodNotAllowed;
        if (eql(path, "/") or eql(path, "/index.html")) return .{ .content_type = "text/html; charset=utf-8", .body = @embedFile("web/index.html") };
        if (eql(path, "/app.css")) return .{ .content_type = "text/css; charset=utf-8", .body = @embedFile("web/app.css") };
        if (eql(path, "/app.js")) return .{ .content_type = "text/javascript; charset=utf-8", .body = @embedFile("web/app.js") };
        return error.NotFound;
    }

    // Only file operations are serialized; idle browser connections cannot
    // block other clients. Each request reads the latest files, including CLI edits.
    state.mutex.lock();
    defer state.mutex.unlock();
    if (eql(path, "/api/state")) {
        if (method != .GET) return error.MethodNotAllowed;
        var config = try Config.load(allocator);
        defer config.deinit();
        const nodes = try Profile.getAll(allocator);
        defer Profile.freeEntries(allocator, nodes);
        const aliases = try Alias.getAll(allocator);
        defer Alias.freeEntries(allocator, aliases);
        return json(allocator, .{
            .config = Config.snapshot(&config),
            .nodes = nodes,
            .aliases = aliases,
            .platform = Alias.Platform.current().toString(),
            .version = build_info.version,
            .commit = build_info.commit,
        });
    }
    if (eql(path, "/api/config")) {
        if (method == .GET) {
            var config = try Config.load(allocator);
            defer config.deinit();
            return json(allocator, Config.snapshot(&config));
        }
        if (method == .DELETE) {
            const config = Config.ConfigData.init(allocator);
            try Config.store(&config);
            return ok();
        }
        if (method != .PUT) return error.MethodNotAllowed;
        const object = try parseObject(allocator, request.body);
        var current = try Config.load(allocator);
        defer current.deinit();
        var updated = try proxyFields(allocator, object);
        updated.node = current.node;
        try Config.store(&updated);
        try Profile.syncActive(allocator);
        return ok();
    }
    if (eql(path, "/api/nodes/order")) {
        if (method != .PUT) return error.MethodNotAllowed;
        const object = try parseObject(allocator, request.body);
        const values = object.get("names") orelse return error.InvalidFields;
        if (values != .array) return error.InvalidFields;
        const names = try allocator.alloc([]const u8, values.array.items.len);
        for (values.array.items, 0..) |value, index| {
            if (value != .string) return error.InvalidFields;
            names[index] = value.string;
        }
        try Profile.reorder(allocator, names);
        return ok();
    }
    if (eql(path, "/api/aliases/order")) {
        if (method != .PUT) return error.MethodNotAllowed;
        const object = try parseObject(allocator, request.body);
        const values = object.get("aliases") orelse return error.InvalidFields;
        if (values != .array) return error.InvalidFields;
        const identities = try allocator.alloc(Alias.Identity, values.array.items.len);
        for (values.array.items, 0..) |value, index| {
            if (value != .object) return error.InvalidFields;
            identities[index] = .{
                .platform = try requiredString(value.object, "platform"),
                .name = try requiredString(value.object, "name"),
            };
        }
        try Alias.reorder(allocator, identities);
        return ok();
    }
    if (eql(path, "/api/nodes/activate")) {
        if (method != .POST) return error.MethodNotAllowed;
        const object = try parseObject(allocator, request.body);
        try Profile.switchTo(allocator, try requiredString(object, "name"));
        return ok();
    }
    if (eql(path, "/api/nodes/unlink")) {
        if (method != .POST) return error.MethodNotAllowed;
        if (try Profile.unlink(allocator)) |old| allocator.free(old);
        return ok();
    }
    if (eql(path, "/api/nodes")) {
        if (method == .GET) {
            const entries = try Profile.getAll(allocator);
            defer Profile.freeEntries(allocator, entries);
            return json(allocator, entries);
        }
        if (!isMutation(method)) return error.MethodNotAllowed;
        const object = try parseObject(allocator, request.body);
        const name = try requiredString(object, "name");
        if (method == .DELETE) {
            try Profile.remove(allocator, name);
            return ok();
        }
        try validateName(name, false);
        const fields = try proxyFields(allocator, object);
        try Profile.storeEntry(allocator, .{
            .name = name,
            .host = fields.host,
            .port = fields.port,
            .protocol = fields.protocol,
            .username = fields.username,
            .password = fields.password,
        }, if (method == .PUT) try requiredString(object, "original_name") else null);
        return .{ .status = if (method == .POST) .created else .ok, .body = "{\"ok\":true}" };
    }
    if (eql(path, "/api/aliases")) {
        if (method == .GET) {
            const entries = try Alias.getAll(allocator);
            defer Alias.freeEntries(allocator, entries);
            return json(allocator, entries);
        }
        if (!isMutation(method)) return error.MethodNotAllowed;
        const object = try parseObject(allocator, request.body);
        const platform = try requiredString(object, "platform");
        const name = try requiredString(object, "name");
        _ = Alias.Platform.fromString(platform) orelse return error.InvalidPlatform;
        if (method == .DELETE) {
            try Alias.removeExisting(allocator, .{ .platform = platform, .name = name });
            return ok();
        }
        try validateName(name, true);
        const raw_command = try requiredString(object, "command");
        if (std.mem.trim(u8, raw_command, " \t\r\n").len == 0 or raw_command.len > 16384 or std.mem.indexOfScalar(u8, raw_command, 0) != null) return error.InvalidAliasCommand;
        // 浏览器 textarea 会提交 \r\n，统一按 \n 保存
        const command = try std.mem.replaceOwned(u8, allocator, raw_command, "\r\n", "\n");
        try Alias.storeEntry(allocator, .{ .platform = platform, .name = name, .command = command }, if (method == .PUT)
            .{ .platform = try requiredString(object, "original_platform"), .name = try requiredString(object, "original_name") }
        else
            null);
        return .{ .status = if (method == .POST) .created else .ok, .body = "{\"ok\":true}" };
    }
    return error.NotFound;
}

fn parseObject(allocator: std.mem.Allocator, bytes: []const u8) !std.json.ObjectMap {
    // The per-request arena owns both the parsed data and request buffer.
    const value = std.json.parseFromSliceLeaky(std.json.Value, allocator, bytes, .{}) catch return error.InvalidJson;
    if (value != .object) return error.InvalidJson;
    return value.object;
}

fn requiredString(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = object.get(name) orelse return error.InvalidFields;
    if (value != .string) return error.InvalidFields;
    return value.string;
}

fn optionalString(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    if (object.get(name)) |value| {
        if (value != .string) return error.InvalidFields;
        return value.string;
    }
    return "";
}

fn proxyFields(allocator: std.mem.Allocator, object: std.json.ObjectMap) !Config.ConfigData {
    const host = try requiredString(object, "host");
    const port = try requiredString(object, "port");
    const protocol = try requiredString(object, "protocol");
    if (host.len == 0 or host.len > 255 or std.mem.indexOfAny(u8, host, " /\\?#@\t\r\n") != null) return error.InvalidProxyHost;
    for (host) |char| if (char < 0x20 or char == 0x7f) return error.InvalidProxyHost;
    if (!Profile.looksLikeIndex(port)) return error.InvalidProxyPort;
    const port_number = std.fmt.parseInt(u16, port, 10) catch return error.InvalidProxyPort;
    if (port_number == 0) return error.InvalidProxyPort;
    if (!eql(protocol, "http") and !eql(protocol, "https") and !eql(protocol, "socks5") and !eql(protocol, "socks4")) return error.InvalidProtocol;
    const username = try optionalString(object, "username");
    const password = try optionalString(object, "password");
    if (username.len > 4096 or password.len > 4096 or std.mem.indexOfScalar(u8, username, 0) != null or std.mem.indexOfScalar(u8, password, 0) != null) return error.InvalidFields;
    return .{ .host = host, .port = port, .protocol = protocol, .username = username, .password = password, .node = "", .allocator = allocator };
}

fn validateName(name: []const u8, alias: bool) !void {
    if (name.len == 0 or name.len > 128 or std.mem.trim(u8, name, " \t\r\n").len != name.len) return error.InvalidName;
    for (name) |char| {
        if (char < 0x20 or char == 0x7f or (alias and char == ' ')) return error.InvalidName;
    }
}

fn json(allocator: std.mem.Allocator, value: anytype) !Response {
    return .{ .body = try std.json.Stringify.valueAlloc(allocator, value, .{}) };
}

fn ok() Response {
    return .{ .body = "{\"ok\":true}" };
}

fn errorResponse(allocator: std.mem.Allocator, err: anyerror) !Response {
    const status: std.http.Status = switch (err) {
        error.Forbidden => .forbidden,
        error.NotFound, error.NodeNotFound, error.AliasNotFound => .not_found,
        error.NameExists, error.OrderChanged => .conflict,
        error.MethodNotAllowed => .method_not_allowed,
        error.BodyTooLarge => .payload_too_large,
        error.HeadersTooLarge => .request_header_fields_too_large,
        error.UnsupportedMediaType => .unsupported_media_type,
        error.ExpectationFailed => .expectation_failed,
        error.Timeout, error.WouldBlock => .request_timeout,
        error.InvalidRequest, error.InvalidJson, error.InvalidFields, error.InvalidOrder, error.InvalidName, error.InvalidNodeName, error.InvalidPlatform, error.InvalidAliasCommand, error.InvalidProxyHost, error.InvalidProxyPort, error.InvalidProtocol => .bad_request,
        else => .internal_server_error,
    };
    const message = switch (err) {
        error.Forbidden => "请从本机管理页面发起请求",
        error.NameExists => "同名配置已存在，请使用其他名称",
        error.OrderChanged => "配置列表已变化，请刷新后重新排序",
        error.InvalidOrder => "排序列表不能包含重复的配置",
        error.NodeNotFound => "节点不存在，请刷新后重试",
        error.AliasNotFound => "别名不存在，请刷新后重试",
        error.NotFound => "页面或接口不存在",
        error.InvalidJson => "请求必须包含有效的 JSON 对象",
        error.InvalidFields => "配置字段缺失或类型错误",
        error.InvalidName, error.InvalidNodeName => "名称不能为空、过长或包含无效空白字符",
        error.InvalidPlatform => "平台必须为 all、windows、linux 或 macos",
        error.InvalidAliasCommand => "请输入有效的别名命令（最多 16 KB）",
        error.InvalidProxyHost => "请输入有效的代理主机地址，不要包含协议或路径",
        error.InvalidProxyPort => "代理端口必须为 1 到 65535 的整数",
        error.InvalidProtocol => "代理协议必须为 http、https、socks5 或 socks4",
        error.MethodNotAllowed => "此接口不支持该请求方法",
        error.UnsupportedMediaType => "请求内容类型必须为 application/json",
        error.BodyTooLarge, error.HeadersTooLarge => "请求内容过大",
        error.ExpectationFailed => "不支持 Expect 请求头",
        error.Timeout, error.WouldBlock => "请求超时，请重试",
        error.InvalidRequest => "HTTP 请求格式错误",
        else => "无法读取或保存配置，请检查配置文件格式和目录权限",
    };
    return .{ .status = status, .body = try std.json.Stringify.valueAlloc(allocator, .{ .err = @errorName(err), .@"error" = message }, .{}) };
}

fn sendResponse(stream: std.net.Stream, response: Response, head_only: bool) !void {
    var buffer: [2048]u8 = undefined;
    const headers = try std.fmt.bufPrint(&buffer, "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n" ++
        "Connection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n" ++
        "Referrer-Policy: no-referrer\r\nX-Frame-Options: DENY\r\n" ++
        "Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self' https://api.github.com; img-src 'self' data:; base-uri 'none'; form-action 'self'; frame-ancestors 'none'\r\n\r\n", .{ @intFromEnum(response.status), response.status.phrase() orelse "", response.content_type, response.body.len });
    try writeSocket(stream, headers);
    if (!head_only) try writeSocket(stream, response.body);
}

fn isMutation(method: std.http.Method) bool {
    return method == .POST or method == .PUT or method == .DELETE;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// Synchronous recv/send honor SO_RCVTIMEO/SO_SNDTIMEO on Windows as well.
fn readSocket(stream: std.net.Stream, buffer: []u8) !usize {
    if (builtin.os.tag == .windows) {
        const w = std.os.windows.ws2_32;
        const n = w.recv(stream.handle, buffer.ptr, @intCast(buffer.len), 0);
        if (n == w.SOCKET_ERROR) return switch (w.WSAGetLastError()) {
            .WSAETIMEDOUT, .WSAEWOULDBLOCK => error.Timeout,
            else => error.ReadFailed,
        };
        return @intCast(n);
    }
    return stream.read(buffer);
}

fn writeSocket(stream: std.net.Stream, bytes: []const u8) !void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const n: usize = if (builtin.os.tag == .windows) blk: {
            const w = std.os.windows.ws2_32;
            const result = w.send(stream.handle, bytes[sent..].ptr, @intCast(@min(bytes.len - sent, std.math.maxInt(i32))), 0);
            if (result == w.SOCKET_ERROR) return error.WriteFailed;
            break :blk @intCast(result);
        } else try stream.write(bytes[sent..]);
        if (n == 0) return error.WriteFailed;
        sent += n;
    }
}

fn closeConnection(stream: std.net.Stream) void {
    defer stream.close();
    // Send FIN and drain unread request bytes before closing. Otherwise Windows
    // can reset the connection and discard an error response (e.g. HTTP 415).
    std.posix.shutdown(stream.handle, .send) catch return;
    var buffer: [4096]u8 = undefined;
    var remaining: usize = max_headers + max_body;
    while (remaining > 0) {
        const n = readSocket(stream, buffer[0..@min(buffer.len, remaining)]) catch return;
        if (n == 0) return;
        remaining -= n;
    }
}

fn setTimeouts(socket: std.posix.socket_t) void {
    if (builtin.os.tag == .windows) {
        const w = std.os.windows.ws2_32;
        const timeout = socket_timeout_ms;
        _ = w.setsockopt(socket, 0xffff, 0x1006, std.mem.asBytes(&timeout), @sizeOf(u32));
        _ = w.setsockopt(socket, 0xffff, 0x1005, std.mem.asBytes(&timeout), @sizeOf(u32));
    } else {
        const timeout = std.posix.timeval{ .sec = socket_timeout_ms / 1000, .usec = 0 };
        std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};
        std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch {};
    }
}

test "serve parses ports and rejects invalid options" {
    try std.testing.expectEqual(@as(?u16, 8080), try parsePort(&.{}));
    try std.testing.expectEqual(@as(?u16, 0), try parsePort(&.{ "--port", "0" }));
    try std.testing.expectEqual(@as(?u16, 65535), try parsePort(&.{ "-p", "65535" }));
    try std.testing.expectEqual(@as(?u16, 9000), try parsePort(&.{"--port=9000"}));
    try std.testing.expectEqual(null, try parsePort(&.{"--help"}));
    try std.testing.expectError(error.InvalidArguments, parsePort(&.{ "--port", "65536" }));
    try std.testing.expectError(error.InvalidArguments, parsePort(&.{ "--port", "-1" }));
    try std.testing.expectError(error.InvalidArguments, parsePort(&.{"--port"}));
    try std.testing.expectError(error.InvalidArguments, parsePort(&.{"unknown"}));
}

test "serve rejects foreign origins and DNS rebinding hosts" {
    try validateHeaders("GET / HTTP/1.1\r\nHost: 127.0.0.1:8080\r\n\r\n", 8080, .GET);
    try validateHeaders("PUT / HTTP/1.1\r\nHost: localhost:8080\r\nOrigin: http://localhost:8080\r\nX-Proxy-Request: 1\r\n\r\n", 8080, .PUT);
    try std.testing.expectError(error.Forbidden, validateHeaders("GET / HTTP/1.1\r\nHost: attacker.test:8080\r\n\r\n", 8080, .GET));
    try std.testing.expectError(error.Forbidden, validateHeaders("PUT / HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nOrigin: https://example.com\r\nX-Proxy-Request: 1\r\n\r\n", 8080, .PUT));
    try std.testing.expectError(error.Forbidden, validateHeaders("PUT / HTTP/1.1\r\nHost: 127.0.0.1:8080\r\n\r\n", 8080, .PUT));
    try std.testing.expectError(error.Forbidden, validateHeaders("GET / HTTP/1.1\r\nHost: localhost:8080\r\nHost: localhost:8080\r\n\r\n", 8080, .GET));
}
