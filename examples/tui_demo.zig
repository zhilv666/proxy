const std = @import("std");
const tui = @import("tui.zig");

pub fn main() !void {
    tui.clearScreen();
    tui.hideCursor();
    defer tui.showCursor();

    // 标题
    tui.moveCursor(2, 35);
    tui.setColor(.bright_cyan);
    tui.setStyle(.bold);
    std.debug.print("Proxy 跨平台代理工具", .{});
    tui.resetColor();

    // 副标题
    tui.moveCursor(3, 38);
    tui.setColor(.cyan);
    std.debug.print("现代化的命令行代理管理", .{});
    tui.resetColor();

    // 配置框
    tui.drawBox(5, 10, 50, 10, "代理配置");

    tui.moveCursor(7, 13);
    tui.setColor(.bright_white);
    std.debug.print("主机: ", .{});
    tui.setColor(.bright_green);
    std.debug.print("127.0.0.1", .{});
    tui.resetColor();

    tui.moveCursor(8, 13);
    tui.setColor(.bright_white);
    std.debug.print("端口: ", .{});
    tui.setColor(.bright_green);
    std.debug.print("7890", .{});
    tui.resetColor();

    tui.moveCursor(9, 13);
    tui.setColor(.bright_white);
    std.debug.print("协议: ", .{});
    tui.setColor(.bright_green);
    std.debug.print("http", .{});
    tui.resetColor();

    tui.moveCursor(10, 13);
    tui.setColor(.bright_white);
    std.debug.print("状态: ", .{});
    tui.drawBadge(10, 20, "已连接", .bright_green);
    tui.resetColor();

    tui.moveCursor(12, 13);
    tui.setColor(.bright_black);
    std.debug.print("用户: admin", .{});
    tui.resetColor();

    // 别名框
    tui.drawBox(5, 65, 50, 10, "命令别名");

    tui.moveCursor(7, 68);
    tui.setColor(.bright_yellow);
    std.debug.print("→ ", .{});
    tui.setColor(.white);
    std.debug.print("ll", .{});
    tui.setColor(.bright_black);
    std.debug.print(" = ", .{});
    tui.setColor(.cyan);
    std.debug.print("ls -lh", .{});
    tui.resetColor();

    tui.moveCursor(8, 68);
    tui.setColor(.bright_yellow);
    std.debug.print("→ ", .{});
    tui.setColor(.white);
    std.debug.print("gs", .{});
    tui.setColor(.bright_black);
    std.debug.print(" = ", .{});
    tui.setColor(.cyan);
    std.debug.print("git status", .{});
    tui.resetColor();

    tui.moveCursor(9, 68);
    tui.setColor(.bright_yellow);
    std.debug.print("→ ", .{});
    tui.setColor(.white);
    std.debug.print("gp", .{});
    tui.setColor(.bright_black);
    std.debug.print(" = ", .{});
    tui.setColor(.cyan);
    std.debug.print("git pull", .{});
    tui.resetColor();

    tui.moveCursor(10, 68);
    tui.setColor(.bright_yellow);
    std.debug.print("→ ", .{});
    tui.setColor(.white);
    std.debug.print("gcm", .{});
    tui.setColor(.bright_black);
    std.debug.print(" = ", .{});
    tui.setColor(.cyan);
    std.debug.print("git commit -m", .{});
    tui.resetColor();

    // 统计框
    tui.drawDoubleBox(16, 10, 50, 8, "统计信息");

    tui.moveCursor(18, 13);
    tui.setColor(.bright_white);
    std.debug.print("总请求数: ", .{});
    tui.setColor(.bright_yellow);
    tui.setStyle(.bold);
    std.debug.print("1,234", .{});
    tui.resetColor();

    tui.moveCursor(19, 13);
    tui.setColor(.bright_white);
    std.debug.print("成功率:   ", .{});
    tui.setColor(.bright_green);
    tui.setStyle(.bold);
    std.debug.print("98.5%", .{});
    tui.resetColor();

    tui.moveCursor(20, 13);
    tui.setColor(.bright_white);
    std.debug.print("平均延迟: ", .{});
    tui.setColor(.bright_cyan);
    tui.setStyle(.bold);
    std.debug.print("45ms", .{});
    tui.resetColor();

    tui.moveCursor(21, 13);
    tui.setColor(.bright_white);
    std.debug.print("活跃连接: ", .{});
    tui.setColor(.bright_magenta);
    tui.setStyle(.bold);
    std.debug.print("8", .{});
    tui.resetColor();

    // 活动框
    tui.drawDoubleBox(16, 65, 50, 8, "最近活动");

    tui.moveCursor(18, 68);
    tui.setColor(.bright_green);
    std.debug.print("✓ ", .{});
    tui.setColor(.bright_black);
    std.debug.print("3分钟前  ", .{});
    tui.setColor(.white);
    std.debug.print("curl google.com", .{});
    tui.resetColor();

    tui.moveCursor(19, 68);
    tui.setColor(.bright_green);
    std.debug.print("✓ ", .{});
    tui.setColor(.bright_black);
    std.debug.print("5分钟前  ", .{});
    tui.setColor(.white);
    std.debug.print("git clone repo", .{});
    tui.resetColor();

    tui.moveCursor(20, 68);
    tui.setColor(.bright_green);
    std.debug.print("✓ ", .{});
    tui.setColor(.bright_black);
    std.debug.print("8分钟前  ", .{});
    tui.setColor(.white);
    std.debug.print("npm install", .{});
    tui.resetColor();

    tui.moveCursor(21, 68);
    tui.setColor(.bright_green);
    std.debug.print("✓ ", .{});
    tui.setColor(.bright_black);
    std.debug.print("12分钟前 ", .{});
    tui.setColor(.white);
    std.debug.print("wget file.zip", .{});
    tui.resetColor();

    // 进度条
    tui.moveCursor(25, 10);
    tui.setColor(.bright_white);
    tui.setStyle(.bold);
    std.debug.print("传输进度", .{});
    tui.resetColor();

    tui.drawProgressBar(27, 10, 40, 75.0, "下载");
    tui.drawProgressBar(28, 10, 40, 45.0, "上传");
    tui.drawProgressBar(29, 10, 40, 92.0, "缓存");

    // 状态标签
    tui.moveCursor(25, 65);
    tui.setColor(.bright_white);
    tui.setStyle(.bold);
    std.debug.print("系统状态", .{});
    tui.resetColor();

    tui.moveCursor(27, 68);
    tui.drawBadge(27, 68, "运行中", .bright_green);
    tui.moveCursor(27, 82);
    tui.drawBadge(27, 82, "低延迟", .bright_cyan);

    tui.moveCursor(28, 68);
    tui.drawBadge(28, 68, "稳定", .bright_green);
    tui.moveCursor(28, 82);
    tui.drawBadge(28, 82, "已优化", .bright_blue);

    tui.moveCursor(29, 68);
    tui.setColor(.bright_green);
    std.debug.print("✓ ", .{});
    tui.setColor(.bright_white);
    std.debug.print("所有服务正常运行", .{});
    tui.resetColor();

    // 分隔线
    tui.drawHorizontalLine(31, 5, 110);

    // 底部信息
    tui.moveCursor(32, 10);
    tui.setColor(.bright_black);
    std.debug.print("快捷键: ", .{});
    tui.setColor(.bright_cyan);
    std.debug.print("[C] ", .{});
    tui.setColor(.white);
    std.debug.print("配置  ", .{});
    tui.setColor(.bright_cyan);
    std.debug.print("[A] ", .{});
    tui.setColor(.white);
    std.debug.print("别名  ", .{});
    tui.setColor(.bright_cyan);
    std.debug.print("[S] ", .{});
    tui.setColor(.white);
    std.debug.print("统计  ", .{});
    tui.setColor(.bright_cyan);
    std.debug.print("[Q] ", .{});
    tui.setColor(.white);
    std.debug.print("退出", .{});
    tui.resetColor();

    // 版本信息
    tui.moveCursor(33, 10);
    tui.setColor(.bright_black);
    tui.setStyle(.italic);
    std.debug.print("Proxy v1.0.0 ❤ Powered by Zig 0.15.2", .{});
    tui.resetColor();

    // 等待提示
    tui.moveCursor(35, 1);
    tui.setColor(.bright_black);
    std.debug.print("按任意键退出...", .{});
    tui.resetColor();

    // 等待输入
    const stdin = std.fs.File.stdin();
    var buf: [1]u8 = undefined;
    _ = try stdin.read(&buf);

    // 清理
    tui.clearScreen();
    tui.showCursor();
}
