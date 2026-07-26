//! 跨平台终端控制层: 原始模式、备用屏幕、按键解析与字符宽度计算。
const std = @import("std");
const builtin = @import("builtin");

pub const is_windows = builtin.os.tag == .windows;

const windows = std.os.windows;

const Handle = if (is_windows) windows.HANDLE else std.posix.fd_t;
const SavedTermios = if (is_windows) void else std.posix.termios;

const CP_UTF8: u32 = 65001;

const ENABLE_PROCESSED_INPUT: u32 = 0x0001;
const ENABLE_LINE_INPUT: u32 = 0x0002;
const ENABLE_ECHO_INPUT: u32 = 0x0004;
const ENABLE_WINDOW_INPUT: u32 = 0x0008;
const ENABLE_MOUSE_INPUT: u32 = 0x0010;
const ENABLE_VIRTUAL_TERMINAL_INPUT: u32 = 0x0200;
const ENABLE_PROCESSED_OUTPUT: u32 = 0x0001;
const ENABLE_WRAP_AT_EOL_OUTPUT: u32 = 0x0002;
const ENABLE_VIRTUAL_TERMINAL_PROCESSING: u32 = 0x0004;

extern "kernel32" fn SetConsoleCP(wCodePageID: windows.UINT) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetConsoleCP() callconv(.winapi) windows.UINT;

pub const Size = struct { w: usize, h: usize };

pub const Error = error{NotATerminal};

pub const Terminal = struct {
    out: Handle,
    in: Handle,
    saved_in_mode: u32 = 0,
    saved_out_mode: u32 = 0,
    saved_in_cp: u32 = 0,
    saved_out_cp: u32 = 0,
    saved_termios: SavedTermios = if (is_windows) {} else undefined,

    pub fn init() !Terminal {
        var self = Terminal{
            .out = std.fs.File.stdout().handle,
            .in = std.fs.File.stdin().handle,
        };

        if (is_windows) {
            var in_mode: windows.DWORD = 0;
            var out_mode: windows.DWORD = 0;
            if (windows.kernel32.GetConsoleMode(self.in, &in_mode) == 0) return Error.NotATerminal;
            if (windows.kernel32.GetConsoleMode(self.out, &out_mode) == 0) return Error.NotATerminal;

            self.saved_in_mode = in_mode;
            self.saved_out_mode = out_mode;
            self.saved_in_cp = GetConsoleCP();
            self.saved_out_cp = windows.kernel32.GetConsoleOutputCP();

            // UTF-8 进出，中文才不会变成乱码。
            _ = SetConsoleCP(CP_UTF8);
            _ = windows.kernel32.SetConsoleOutputCP(CP_UTF8);

            // 输出端启用 ANSI 转义序列。
            const new_out = out_mode | ENABLE_PROCESSED_OUTPUT |
                ENABLE_WRAP_AT_EOL_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING;
            if (windows.kernel32.SetConsoleMode(self.out, new_out) == 0) return Error.NotATerminal;

            // 输入端改为原始模式，并让方向键以 ANSI 序列送达，与 POSIX 一致。
            var new_in = in_mode;
            new_in &= ~(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT |
                ENABLE_WINDOW_INPUT | ENABLE_MOUSE_INPUT);
            new_in |= ENABLE_VIRTUAL_TERMINAL_INPUT;
            if (windows.kernel32.SetConsoleMode(self.in, new_in) == 0) return Error.NotATerminal;
        } else {
            const saved = std.posix.tcgetattr(self.in) catch return Error.NotATerminal;
            self.saved_termios = saved;

            var raw = saved;
            raw.lflag.ECHO = false;
            raw.lflag.ICANON = false;
            raw.lflag.ISIG = false;
            raw.lflag.IEXTEN = false;
            raw.iflag.IXON = false;
            raw.iflag.ICRNL = false;
            raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
            raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
            std.posix.tcsetattr(self.in, .FLUSH, raw) catch return Error.NotATerminal;
        }

        // 进入备用屏幕并隐藏光标，退出时终端内容可完整恢复。
        self.write("\x1b[?1049h\x1b[?25l\x1b[2J");
        return self;
    }

    pub fn deinit(self: *Terminal) void {
        self.write("\x1b[0m\x1b[?25h\x1b[?1049l");

        if (is_windows) {
            _ = windows.kernel32.SetConsoleMode(self.in, self.saved_in_mode);
            _ = windows.kernel32.SetConsoleMode(self.out, self.saved_out_mode);
            if (self.saved_in_cp != 0) _ = SetConsoleCP(self.saved_in_cp);
            if (self.saved_out_cp != 0) _ = windows.kernel32.SetConsoleOutputCP(self.saved_out_cp);
        } else {
            std.posix.tcsetattr(self.in, .FLUSH, self.saved_termios) catch {};
        }
    }

    pub fn write(self: *const Terminal, bytes: []const u8) void {
        var index: usize = 0;
        while (index < bytes.len) {
            if (is_windows) {
                var written: windows.DWORD = 0;
                const ok = windows.kernel32.WriteFile(
                    self.out,
                    bytes.ptr + index,
                    @intCast(bytes.len - index),
                    &written,
                    null,
                );
                if (ok == 0 or written == 0) return;
                index += written;
            } else {
                const n = std.posix.write(self.out, bytes[index..]) catch return;
                if (n == 0) return;
                index += n;
            }
        }
    }

    pub fn read(self: *const Terminal, buf: []u8) !usize {
        if (is_windows) {
            return try windows.ReadFile(self.in, buf, null);
        }
        return try std.posix.read(self.in, buf);
    }

    /// 等待输入，最多 timeout_ms 毫秒。返回是否有输入可读。
    /// 用于空闲时轮询窗口尺寸变化 (终端没有跨平台的 resize 事件)。
    pub fn pollInput(self: *const Terminal, timeout_ms: u32) bool {
        if (is_windows) {
            return windows.kernel32.WaitForSingleObject(self.in, timeout_ms) == windows.WAIT_OBJECT_0;
        }
        var fds = [_]std.posix.pollfd{.{
            .fd = self.in,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const n = std.posix.poll(&fds, @intCast(timeout_ms)) catch return true;
        return n > 0;
    }

    pub fn size(self: *const Terminal) Size {
        if (is_windows) {
            var info: windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
            if (windows.kernel32.GetConsoleScreenBufferInfo(self.out, &info) != 0) {
                const w = @as(i32, info.srWindow.Right) - @as(i32, info.srWindow.Left) + 1;
                const h = @as(i32, info.srWindow.Bottom) - @as(i32, info.srWindow.Top) + 1;
                if (w > 0 and h > 0) return .{ .w = @intCast(w), .h = @intCast(h) };
            }
        } else {
            var ws: std.posix.winsize = undefined;
            const rc = std.posix.system.ioctl(self.out, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
            if (rc == 0 and ws.col > 0 and ws.row > 0) {
                return .{ .w = ws.col, .h = ws.row };
            }
        }
        return .{ .w = 80, .h = 24 };
    }
};

pub const Key = union(enum) {
    char: u21,
    ctrl: u8,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    enter,
    escape,
    backspace,
    tab,
    delete,
    unknown,
};

/// 按块读取并解析按键。终端总是把一个转义序列一次性写入，
/// 因此按块缓冲即可区分单独的 Esc 与方向键序列，无需超时探测。
pub const Input = struct {
    term: *Terminal,
    buf: [512]u8 = undefined,
    len: usize = 0,
    pos: usize = 0,

    pub fn init(term: *Terminal) Input {
        return .{ .term = term };
    }

    /// 缓冲区里是否还有未消费的按键 (有则无需再等待输入)。
    pub fn hasBuffered(self: *const Input) bool {
        return self.pos < self.len;
    }

    pub fn next(self: *Input) !Key {
        if (self.pos >= self.len) {
            self.pos = 0;
            self.len = try self.term.read(&self.buf);
            if (self.len == 0) return error.EndOfStream;
        }

        const b = self.buf[self.pos];
        switch (b) {
            0x1b => return self.parseEscape(),
            '\r', '\n' => {
                self.pos += 1;
                return .enter;
            },
            0x7f, 0x08 => {
                self.pos += 1;
                return .backspace;
            },
            '\t' => {
                self.pos += 1;
                return .tab;
            },
            else => {
                if (b < 0x20) {
                    self.pos += 1;
                    return .{ .ctrl = b };
                }
                const n = std.unicode.utf8ByteSequenceLength(b) catch {
                    self.pos += 1;
                    return .unknown;
                };
                if (self.pos + n > self.len) {
                    self.pos = self.len;
                    return .unknown;
                }
                const cp = std.unicode.utf8Decode(self.buf[self.pos..][0..n]) catch {
                    self.pos += 1;
                    return .unknown;
                };
                self.pos += n;
                return .{ .char = cp };
            },
        }
    }

    fn parseEscape(self: *Input) Key {
        const start = self.pos;
        if (self.len - start == 1) {
            self.pos += 1;
            return .escape;
        }

        const c1 = self.buf[start + 1];
        if (c1 != '[' and c1 != 'O') {
            self.pos += 1;
            return .escape;
        }

        var i = start + 2;
        while (i < self.len and (std.ascii.isDigit(self.buf[i]) or self.buf[i] == ';')) : (i += 1) {}
        if (i >= self.len) {
            self.pos += 1;
            return .escape;
        }

        const final = self.buf[i];
        const params = self.buf[start + 2 .. i];
        self.pos = i + 1;

        return switch (final) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            'H' => .home,
            'F' => .end,
            '~' => blk: {
                var it = std.mem.splitScalar(u8, params, ';');
                const n = std.fmt.parseInt(u8, it.first(), 10) catch break :blk Key.unknown;
                break :blk switch (n) {
                    1, 7 => Key.home,
                    3 => Key.delete,
                    4, 8 => Key.end,
                    5 => Key.page_up,
                    6 => Key.page_down,
                    else => Key.unknown,
                };
            },
            else => .unknown,
        };
    }
};

/// 终端列宽: 中日韩字符占两列，组合符号占零列。
pub fn charWidth(cp: u21) u8 {
    if (cp < 0x20) return 0;
    if (cp < 0x7f) return 1;
    if (cp == 0x7f) return 0;
    if ((cp >= 0x0300 and cp <= 0x036F) or (cp >= 0x200B and cp <= 0x200F) or cp == 0xFEFF) return 0;
    if (isWide(cp)) return 2;
    return 1;
}

fn isWide(cp: u21) bool {
    return (cp >= 0x1100 and cp <= 0x115F) or
        (cp >= 0x2E80 and cp <= 0x303E) or
        (cp >= 0x3041 and cp <= 0x33FF) or
        (cp >= 0x3400 and cp <= 0x4DBF) or
        (cp >= 0x4E00 and cp <= 0x9FFF) or
        (cp >= 0xA000 and cp <= 0xA4CF) or
        (cp >= 0xA960 and cp <= 0xA97F) or
        (cp >= 0xAC00 and cp <= 0xD7A3) or
        (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0xFE10 and cp <= 0xFE19) or
        (cp >= 0xFE30 and cp <= 0xFE6F) or
        (cp >= 0xFF00 and cp <= 0xFF60) or
        (cp >= 0xFFE0 and cp <= 0xFFE6) or
        (cp >= 0x1F300 and cp <= 0x1F64F) or
        (cp >= 0x1F900 and cp <= 0x1F9FF) or
        (cp >= 0x20000 and cp <= 0x3FFFD);
}

pub fn strWidth(s: []const u8) usize {
    var total: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            i += 1;
            total += 1;
            continue;
        };
        if (i + n > s.len) break;
        const cp = std.unicode.utf8Decode(s[i..][0..n]) catch {
            i += 1;
            total += 1;
            continue;
        };
        total += charWidth(cp);
        i += n;
    }
    return total;
}

/// 返回不超过 max_width 列的最长前缀的字节长度，不会切断多字节字符。
pub fn truncateBytes(s: []const u8, max_width: usize) usize {
    var used: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch break;
        if (i + n > s.len) break;
        const cp = std.unicode.utf8Decode(s[i..][0..n]) catch break;
        const w = charWidth(cp);
        if (used + w > max_width) break;
        used += w;
        i += n;
    }
    return i;
}

test "strWidth counts CJK as two columns" {
    try std.testing.expectEqual(@as(usize, 8), strWidth("代理配置"));
    try std.testing.expectEqual(@as(usize, 5), strWidth("proxy"));
    try std.testing.expectEqual(@as(usize, 9), strWidth("端口 port"));
}

test "truncateBytes never splits a codepoint" {
    const s = "代理配置";
    try std.testing.expectEqual(@as(usize, 3), truncateBytes(s, 2));
    try std.testing.expectEqual(@as(usize, 3), truncateBytes(s, 3));
    try std.testing.expectEqual(@as(usize, 6), truncateBytes(s, 4));
    try std.testing.expectEqual(@as(usize, 0), truncateBytes(s, 1));
}
