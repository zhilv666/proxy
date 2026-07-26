const std = @import("std");
const builtin = @import("builtin");

var is_console_initialized = false;

/// Initialize Windows console for UTF-8 output
pub fn initConsole() void {
    if (builtin.os.tag == .windows and !is_console_initialized) {
        const windows = std.os.windows;
        const kernel32 = windows.kernel32;

        // Set console output code page to UTF-8 (65001)
        _ = kernel32.SetConsoleOutputCP(65001);

        is_console_initialized = true;
    }
}

/// Print UTF-8 text to stdout with proper encoding on Windows
pub fn print(comptime fmt: []const u8, args: anytype) void {
    initConsole();

    if (builtin.os.tag == .windows) {
        printWindows(fmt, args) catch {};
    } else {
        std.debug.print(fmt, args);
    }
}

/// Print UTF-8 text to stdout on Windows using WriteFile
fn printWindows(comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, fmt, args);

    const windows = std.os.windows;
    const stdout_handle = try windows.GetStdHandle(windows.STD_OUTPUT_HANDLE);

    var written: u32 = undefined;
    _ = windows.kernel32.WriteFile(
        stdout_handle,
        text.ptr,
        @intCast(text.len),
        &written,
        null,
    );
}

/// Writer that works correctly with UTF-8 on Windows
pub const Writer = if (builtin.os.tag == .windows) WindowsWriter else PosixWriter;

const PosixWriter = struct {
    handle: std.posix.fd_t,

    pub fn init() PosixWriter {
        return .{ .handle = std.fs.File.stdout().handle };
    }

    pub fn write(self: PosixWriter, bytes: []const u8) !usize {
        return try std.posix.write(self.handle, bytes);
    }

    pub fn writeAll(self: PosixWriter, bytes: []const u8) !void {
        var index: usize = 0;
        while (index < bytes.len) {
            index += try self.write(bytes[index..]);
        }
    }

    pub fn print(self: PosixWriter, comptime fmt: []const u8, args: anytype) !void {
        var buf: [4096]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, fmt, args);
        try self.writeAll(text);
    }
};

const WindowsWriter = struct {
    handle: std.os.windows.HANDLE,

    pub fn init() !WindowsWriter {
        initConsole();

        const windows = std.os.windows;
        const handle = try windows.GetStdHandle(windows.STD_OUTPUT_HANDLE);
        return .{ .handle = handle };
    }

    pub fn write(self: WindowsWriter, bytes: []const u8) !usize {
        var written: u32 = undefined;
        const windows = std.os.windows;
        const result = windows.kernel32.WriteFile(
            self.handle,
            bytes.ptr,
            @intCast(bytes.len),
            &written,
            null,
        );
        if (result == 0) return error.WriteFailed;
        return written;
    }

    pub fn writeAll(self: WindowsWriter, bytes: []const u8) !void {
        var index: usize = 0;
        while (index < bytes.len) {
            const written = try self.write(bytes[index..]);
            index += written;
        }
    }

    pub fn print(self: WindowsWriter, comptime fmt: []const u8, args: anytype) !void {
        var buf: [4096]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, fmt, args);
        try self.writeAll(text);
    }
};

/// Get a writer for stdout that handles UTF-8 correctly
pub fn getWriter() !Writer {
    if (builtin.os.tag == .windows) {
        return try WindowsWriter.init();
    } else {
        return PosixWriter.init();
    }
}
