const std = @import("std");

pub const Color = enum {
    reset,
    black,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    bright_black,
    bright_red,
    bright_green,
    bright_yellow,
    bright_blue,
    bright_magenta,
    bright_cyan,
    bright_white,

    pub fn code(self: Color) []const u8 {
        return switch (self) {
            .reset => "\x1b[0m",
            .black => "\x1b[30m",
            .red => "\x1b[31m",
            .green => "\x1b[32m",
            .yellow => "\x1b[33m",
            .blue => "\x1b[34m",
            .magenta => "\x1b[35m",
            .cyan => "\x1b[36m",
            .white => "\x1b[37m",
            .bright_black => "\x1b[90m",
            .bright_red => "\x1b[91m",
            .bright_green => "\x1b[92m",
            .bright_yellow => "\x1b[93m",
            .bright_blue => "\x1b[94m",
            .bright_magenta => "\x1b[95m",
            .bright_cyan => "\x1b[96m",
            .bright_white => "\x1b[97m",
        };
    }
};

pub const Style = enum {
    bold,
    dim,
    italic,
    underline,
    blink,
    reverse,
    hidden,

    pub fn code(self: Style) []const u8 {
        return switch (self) {
            .bold => "\x1b[1m",
            .dim => "\x1b[2m",
            .italic => "\x1b[3m",
            .underline => "\x1b[4m",
            .blink => "\x1b[5m",
            .reverse => "\x1b[7m",
            .hidden => "\x1b[8m",
        };
    }
};

const print = std.debug.print;

pub fn clearScreen() void {
    print("\x1b[2J\x1b[H", .{});
}

pub fn moveCursor(row: usize, col: usize) void {
    print("\x1b[{d};{d}H", .{ row, col });
}

pub fn hideCursor() void {
    print("\x1b[?25l", .{});
}

pub fn showCursor() void {
    print("\x1b[?25h", .{});
}

pub fn setColor(color: Color) void {
    print("{s}", .{color.code()});
}

pub fn setStyle(style: Style) void {
    print("{s}", .{style.code()});
}

pub fn resetColor() void {
    print("{s}", .{Color.reset.code()});
}

pub fn drawBox(row: usize, col: usize, width: usize, height: usize, title: []const u8) void {
    // Top border with rounded corners
    moveCursor(row, col);
    print("╭", .{});
    if (title.len > 0) {
        setStyle(.bold);
        setColor(.bright_cyan);
        print(" {s} ", .{title});
        resetColor();
        const title_len = title.len + 2;
        var i: usize = 0;
        while (i < width - title_len - 2) : (i += 1) {
            print("─", .{});
        }
    } else {
        var i: usize = 0;
        while (i < width - 2) : (i += 1) {
            print("─", .{});
        }
    }
    print("╮", .{});

    // Sides
    var r: usize = 1;
    while (r < height - 1) : (r += 1) {
        moveCursor(row + r, col);
        print("│", .{});
        moveCursor(row + r, col + width - 1);
        print("│", .{});
    }

    // Bottom border with rounded corners
    moveCursor(row + height - 1, col);
    print("╰", .{});
    var i: usize = 0;
    while (i < width - 2) : (i += 1) {
        print("─", .{});
    }
    print("╯", .{});
}

pub fn drawDoubleBox(row: usize, col: usize, width: usize, height: usize, title: []const u8) void {
    // Top border
    moveCursor(row, col);
    print("╔", .{});
    if (title.len > 0) {
        setStyle(.bold);
        setColor(.bright_yellow);
        print(" {s} ", .{title});
        resetColor();
        const title_len = title.len + 2;
        var i: usize = 0;
        while (i < width - title_len - 2) : (i += 1) {
            print("═", .{});
        }
    } else {
        var i: usize = 0;
        while (i < width - 2) : (i += 1) {
            print("═", .{});
        }
    }
    print("╗", .{});

    // Sides
    var r: usize = 1;
    while (r < height - 1) : (r += 1) {
        moveCursor(row + r, col);
        print("║", .{});
        moveCursor(row + r, col + width - 1);
        print("║", .{});
    }

    // Bottom border
    moveCursor(row + height - 1, col);
    print("╚", .{});
    var i: usize = 0;
    while (i < width - 2) : (i += 1) {
        print("═", .{});
    }
    print("╝", .{});
}

pub fn printAt(row: usize, col: usize, text: []const u8) void {
    moveCursor(row, col);
    print("{s}", .{text});
}

pub fn printColorAt(row: usize, col: usize, color: Color, text: []const u8) void {
    moveCursor(row, col);
    setColor(color);
    print("{s}", .{text});
    resetColor();
}

pub fn drawProgressBar(row: usize, col: usize, width: usize, percent: f32, label: []const u8) void {
    moveCursor(row, col);

    // Label
    setColor(.bright_white);
    print("{s}: ", .{label});
    resetColor();

    const bar_width = width - label.len - 10;
    const filled = @as(usize, @intFromFloat(@as(f32, @floatFromInt(bar_width)) * percent / 100.0));

    // Progress bar
    print("[", .{});

    var i: usize = 0;
    while (i < filled) : (i += 1) {
        if (percent < 33) {
            setColor(.bright_red);
        } else if (percent < 66) {
            setColor(.bright_yellow);
        } else {
            setColor(.bright_green);
        }
        print("█", .{});
    }

    resetColor();
    setColor(.bright_black);
    while (i < bar_width) : (i += 1) {
        print("░", .{});
    }
    resetColor();

    print("] {d:>3.0}%", .{percent});
}

pub fn drawHorizontalLine(row: usize, col: usize, width: usize) void {
    moveCursor(row, col);
    var i: usize = 0;
    while (i < width) : (i += 1) {
        print("─", .{});
    }
}

pub fn drawBadge(row: usize, col: usize, text: []const u8, color: Color) void {
    moveCursor(row, col);
    setColor(color);
    setStyle(.bold);
    print(" {s} ", .{text});
    resetColor();
}
