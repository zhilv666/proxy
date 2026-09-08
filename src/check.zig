//! 代理连通性检测: TCP 握手延迟 + 经代理的 HTTP 请求测试。
//! `proxy status` / `proxy check [test url]`
const std = @import("std");
const builtin = @import("builtin");
const Config = @import("config.zig");
const output = @import("output.zig");

const rounds = 3;
const timeout_ms = 5000;
const default_test_url = "http://www.gstatic.com/generate_204";

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var config = try Config.load(allocator);
    defer config.deinit();

    const host = if (config.host.len > 0) config.host else "127.0.0.1";
    const port_str = if (config.port.len > 0) config.port else "7890";
    const protocol = if (config.protocol.len > 0) config.protocol else "http";
    const port = std.fmt.parseInt(u16, port_str, 10) catch {
        output.print("error: invalid port config: {s}\n", .{port_str});
        return;
    };
    const test_url = if (args.len > 0) args[0] else default_test_url;

    const proxy_url = try config.buildProxyUrl(allocator);
    defer allocator.free(proxy_url);

    output.print("Proxy status check\n\n", .{});
    output.print("  proxy url   {s}\n", .{proxy_url});
    if (config.node.len > 0) {
        output.print("  node        {s}{s}\n", .{
            config.node,
            if (Config.isEphemeral()) " (ephemeral)" else "",
        });
    }
    output.print("  test url   {s}\n\n", .{test_url});

    // -- TCP 握手延迟 ------------------------------------------------------
    var ok_count: usize = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;
    var sum_ns: u64 = 0;
    var last_err: ?anyerror = null;

    var i: usize = 0;
    while (i < rounds) : (i += 1) {
        var timer = try std.time.Timer.start();
        const stream = std.net.tcpConnectToHost(allocator, host, port) catch |err| {
            last_err = err;
            continue;
        };
        const ns = timer.read();
        stream.close();
        ok_count += 1;
        min_ns = @min(min_ns, ns);
        max_ns = @max(max_ns, ns);
        sum_ns += ns;
    }

    if (ok_count == 0) {
        output.print("  TCP         ✗ 0/{d} all failed: {s}\n", .{ rounds, @errorName(last_err.?) });
        output.print("\n  status      ✗ unreachable (cannot connect to proxy port)\n", .{});
        return;
    }
    output.print("  TCP         ✓ {d}/{d} ok   latency {d:.2} / {d:.2} / {d:.2} ms (min/avg/max)\n", .{
        ok_count,
        rounds,
        toMs(min_ns),
        toMs(sum_ns / ok_count),
        toMs(max_ns),
    });

    // -- 经代理的 HTTP 请求 -------------------------------------------------
    if (std.mem.eql(u8, protocol, "https")) {
        output.print("  HTTP        - skipped (https proxy needs TLS to the proxy; unsupported)\n", .{});
        output.print("\n  status      ✓ port reachable (forwarding not verified)\n", .{});
        return;
    }

    const url = parseUrl(test_url) orelse {
        output.print("  HTTP        ✗ invalid test URL (only http:// and https:// supported)\n", .{});
        return;
    };

    var timer = try std.time.Timer.start();
    const code = httpProbe(allocator, &config, protocol, host, port, url, test_url) catch |err| {
        output.print("  HTTP        ✗ failed: {s}\n", .{@errorName(err)});
        if (err == error.Socks5AuthRequired) {
            output.print("             (proxy requires SOCKS5 auth; unsupported)\n", .{});
        }
        output.print("\n  status      ✗ port reachable, but forwarding failed\n", .{});
        return;
    };
    const elapsed = timer.read() / std.time.ns_per_ms;

    if (code == 0) {
        // socks5 + https: 隧道建立即视为成功
        output.print("  HTTP        ✓ tunnel established   {d} ms\n", .{elapsed});
        output.print("\n  status      ✓ available\n", .{});
        return;
    }

    output.print("  HTTP        {s} HTTP {d}   {d} ms\n", .{
        if (code < 400) "✓" else "✗",
        code,
        elapsed,
    });
    if (code < 400) {
        output.print("\n  status      ✓ available\n", .{});
    } else if (code == 407) {
        output.print("\n  status      ✗ proxy requires auth (check username/password config)\n", .{});
    } else {
        output.print("\n  status      ✗ abnormal (HTTP {d})\n", .{code});
    }
}

fn toMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

const Url = struct {
    https: bool,
    host: []const u8,
    port: u16,
    path: []const u8,
};

fn parseUrl(url: []const u8) ?Url {
    var rest: []const u8 = undefined;
    var https = false;
    if (std.mem.startsWith(u8, url, "http://")) {
        rest = url[7..];
    } else if (std.mem.startsWith(u8, url, "https://")) {
        https = true;
        rest = url[8..];
    } else {
        return null;
    }

    var host_part = rest;
    var path: []const u8 = "/";
    if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
        host_part = rest[0..slash];
        path = rest[slash..];
    }

    var host = host_part;
    var port: u16 = if (https) 443 else 80;
    if (std.mem.indexOfScalar(u8, host_part, ':')) |colon| {
        host = host_part[0..colon];
        port = std.fmt.parseInt(u16, host_part[colon + 1 ..], 10) catch return null;
    }
    if (host.len == 0 or host.len > 255) return null;

    return .{ .https = https, .host = host, .port = port, .path = path };
}

/// 经代理请求test url。返回 HTTP 状态码；socks5 + https 隧道建立返回 0。
fn httpProbe(
    allocator: std.mem.Allocator,
    config: *const Config.ConfigData,
    protocol: []const u8,
    proxy_host: []const u8,
    proxy_port: u16,
    url: Url,
    raw_url: []const u8,
) !u32 {
    const stream = try std.net.tcpConnectToHost(allocator, proxy_host, proxy_port);
    defer stream.close();
    setTimeouts(stream.handle, timeout_ms);

    var req_buf: [2048]u8 = undefined;

    const is_socks5 = std.mem.eql(u8, protocol, "socks5");
    const is_socks4 = std.mem.eql(u8, protocol, "socks4");
    if (is_socks5 or is_socks4) {
        if (is_socks5) {
            try socks5Connect(stream, url.host, url.port);
        } else {
            try socks4Connect(stream, url.host, url.port);
        }
        if (url.https) return 0;
        const req = try std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: proxy-check\r\nConnection: close\r\n\r\n", .{ url.path, url.host });
        try writeAll(stream, req);
        return try readStatus(stream);
    }

    // http 代理，带认证时附加 Basic 凭据
    var auth_buf: [512]u8 = undefined;
    var auth: []const u8 = "";
    if (config.username.len > 0 and config.password.len > 0) {
        var cred_buf: [128]u8 = undefined;
        const cred = std.fmt.bufPrint(&cred_buf, "{s}:{s}", .{ config.username, config.password }) catch
            return error.CredentialsTooLong;
        var b64_buf: [256]u8 = undefined;
        const b64 = std.base64.standard.Encoder.encode(&b64_buf, cred);
        auth = try std.fmt.bufPrint(&auth_buf, "Proxy-Authorization: Basic {s}\r\n", .{b64});
    }

    if (url.https) {
        const req = try std.fmt.bufPrint(&req_buf, "CONNECT {s}:{d} HTTP/1.1\r\nHost: {s}:{d}\r\n{s}\r\n", .{ url.host, url.port, url.host, url.port, auth });
        try writeAll(stream, req);
        return try readStatus(stream);
    }

    const req = try std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: proxy-check\r\n{s}Connection: close\r\n\r\n", .{ raw_url, url.host, auth });
    try writeAll(stream, req);
    return try readStatus(stream);
}

/// SOCKS5 无认证握手 + CONNECT 到目标。
fn socks5Connect(stream: std.net.Stream, host: []const u8, port: u16) !void {
    try writeAll(stream, &.{ 5, 1, 0 });
    var buf: [262]u8 = undefined;
    try readExact(stream, buf[0..2]);
    if (buf[0] != 5) return error.NotSocks5;
    if (buf[1] != 0) return error.Socks5AuthRequired;

    var req: [262]u8 = undefined;
    req[0] = 5; // VER
    req[1] = 1; // CMD: CONNECT
    req[2] = 0; // RSV
    req[3] = 3; // ATYP: 域名
    req[4] = @intCast(host.len);
    @memcpy(req[5..][0..host.len], host);
    req[5 + host.len] = @intCast(port >> 8);
    req[6 + host.len] = @intCast(port & 0xff);
    try writeAll(stream, req[0 .. 7 + host.len]);

    try readExact(stream, buf[0..4]);
    if (buf[0] != 5) return error.Socks5BadReply;
    if (buf[1] != 0) return error.Socks5ConnectFailed;
    // 读完绑定地址，长度取决于地址类型
    switch (buf[3]) {
        1 => try readExact(stream, buf[0..6]),
        3 => {
            try readExact(stream, buf[0..1]);
            const alen: usize = buf[0];
            try readExact(stream, buf[0 .. alen + 2]);
        },
        4 => try readExact(stream, buf[0..18]),
        else => return error.Socks5BadReply,
    }
}

/// SOCKS4a CONNECT: IP 置 0.0.0.1，域名放在 userid 之后，由代理侧解析。
fn socks4Connect(stream: std.net.Stream, host: []const u8, port: u16) !void {
    var req: [512]u8 = undefined;
    req[0] = 4; // VN
    req[1] = 1; // CD: CONNECT
    req[2] = @intCast(port >> 8);
    req[3] = @intCast(port & 0xff);
    req[4] = 0; // 0.0.0.1 = socks4a 域名标记
    req[5] = 0;
    req[6] = 0;
    req[7] = 1;
    req[8] = 0; // 空 userid
    @memcpy(req[9..][0..host.len], host);
    req[9 + host.len] = 0;
    try writeAll(stream, req[0 .. 10 + host.len]);

    var resp: [8]u8 = undefined;
    try readExact(stream, &resp);
    if (resp[1] != 0x5A) return error.Socks4ConnectFailed;
}

/// 读取响应首行并解析状态码，如 "HTTP/1.1 204 No Content" -> 204。
fn readStatus(stream: std.net.Stream) !u32 {
    var buf: [1024]u8 = undefined;
    var n: usize = 0;
    while (n < buf.len) {
        const r = try streamRead(stream, buf[n..]);
        if (r == 0) break;
        n += r;
        if (std.mem.indexOfScalar(u8, buf[0..n], '\n') != null) break;
    }
    const line_end = std.mem.indexOfScalar(u8, buf[0..n], '\n') orelse n;
    const line = buf[0..line_end];
    if (!std.mem.startsWith(u8, line, "HTTP/")) return error.BadHttpResponse;
    const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return error.BadHttpResponse;
    if (line.len < sp + 4) return error.BadHttpResponse;
    return std.fmt.parseInt(u32, line[sp + 1 .. sp + 4], 10) catch error.BadHttpResponse;
}

/// Windows 上 Stream.read 走 ReadFile，与 overlapped socket + SO_RCVTIMEO
/// 组合会报 ERROR_INVALID_PARAMETER，因此统一用 recv/send。
fn streamRead(stream: std.net.Stream, buf: []u8) !usize {
    if (builtin.os.tag == .windows) {
        const w = std.os.windows;
        const len: i32 = @intCast(@min(buf.len, std.math.maxInt(i32)));
        const rc = w.ws2_32.recv(stream.handle, buf.ptr, len, 0);
        if (rc == w.ws2_32.SOCKET_ERROR) {
            return switch (w.ws2_32.WSAGetLastError()) {
                .WSAETIMEDOUT => error.Timeout,
                .WSAECONNRESET => error.ConnectionResetByPeer,
                else => error.ReadFailed,
            };
        }
        return @intCast(rc);
    }
    return stream.read(buf);
}

fn streamWrite(stream: std.net.Stream, bytes: []const u8) !usize {
    if (builtin.os.tag == .windows) {
        const w = std.os.windows;
        const len: i32 = @intCast(@min(bytes.len, std.math.maxInt(i32)));
        const rc = w.ws2_32.send(stream.handle, bytes.ptr, len, 0);
        if (rc == w.ws2_32.SOCKET_ERROR) {
            return switch (w.ws2_32.WSAGetLastError()) {
                .WSAETIMEDOUT => error.Timeout,
                else => error.WriteFailed,
            };
        }
        return @intCast(rc);
    }
    return stream.write(bytes);
}

fn writeAll(stream: std.net.Stream, bytes: []const u8) !void {
    var n: usize = 0;
    while (n < bytes.len) {
        n += try streamWrite(stream, bytes[n..]);
    }
}

fn readExact(stream: std.net.Stream, buf: []u8) !void {
    var n: usize = 0;
    while (n < buf.len) {
        const r = try streamRead(stream, buf[n..]);
        if (r == 0) return error.UnexpectedEof;
        n += r;
    }
}

/// 读写超时，防止代理挂起时检测卡死。
fn setTimeouts(sock: std.posix.socket_t, ms: u32) void {
    if (builtin.os.tag == .windows) {
        const w = std.os.windows;
        const t: u32 = ms; // DWORD 毫秒
        const opt: [*]const u8 = @ptrCast(&t);
        _ = w.ws2_32.setsockopt(sock, 0xffff, 0x1006, opt, @sizeOf(u32)); // SO_RCVTIMEO
        _ = w.ws2_32.setsockopt(sock, 0xffff, 0x1005, opt, @sizeOf(u32)); // SO_SNDTIMEO
    } else {
        const tv = std.posix.timeval{
            .sec = @intCast(ms / 1000),
            .usec = @intCast((ms % 1000) * 1000),
        };
        std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
        std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch {};
    }
}

test "parseUrl 解析 http/https 与端口" {
    const plain = parseUrl("http://example.com/generate_204").?;
    try std.testing.expect(!plain.https);
    try std.testing.expectEqualStrings("example.com", plain.host);
    try std.testing.expectEqual(@as(u16, 80), plain.port);
    try std.testing.expectEqualStrings("/generate_204", plain.path);

    const tls = parseUrl("https://example.com").?;
    try std.testing.expect(tls.https);
    try std.testing.expectEqual(@as(u16, 443), tls.port);
    try std.testing.expectEqualStrings("/", tls.path);

    const with_port = parseUrl("http://127.0.0.1:8080/x").?;
    try std.testing.expectEqual(@as(u16, 8080), with_port.port);
    try std.testing.expectEqualStrings("127.0.0.1", with_port.host);

    try std.testing.expect(parseUrl("ftp://x") == null);
    try std.testing.expect(parseUrl("http://") == null);
    try std.testing.expect(parseUrl("http://host:notaport/") == null);
}
