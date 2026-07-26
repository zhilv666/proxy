//! 全屏交互式 TUI: 基于 term.zig 的原始模式渲染。
//! 主-从布局: 左侧节点/别名列表，右侧详情面板随选中项实时切换并可逐字段编辑。
const std = @import("std");
const Config = @import("config.zig");
const Alias = @import("alias.zig");
const Profile = @import("profile.zig");
const term = @import("term.zig");
const output = @import("output.zig");

/// ANSI 转义码。行内切色不用 reset，避免破坏选中行的反色。
const A = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const dim = "\x1b[90m";
    const rev = "\x1b[7m";
    const cyan = "\x1b[36m";
    const bcyan = "\x1b[96m";
    const green = "\x1b[92m";
    const yellow = "\x1b[93m";
    const bred = "\x1b[91m";
    const bwhite = "\x1b[97m";
};

/// 每行行尾: 清除残留字符再换行。
const EOL = "\x1b[K\r\n";

const platforms = [_][]const u8{ "all", "windows", "linux", "macos" };

fn platIndex(name: []const u8) ?usize {
    for (platforms, 0..) |p, i| {
        if (std.mem.eql(u8, p, name)) return i;
    }
    return null;
}

/// 显示用别名分组: 同名同命令的记录跨平台合并为一行，避免列表重复臃肿。
/// name/command 借用 aliases 里的内存，随 reload 一起重建。
const Group = struct {
    name: []const u8,
    command: []const u8,
    plats: [platforms.len]bool = .{ false, false, false, false },
    tags: [48]u8 = undefined,
    tags_len: usize = 0,
};

const Field = struct {
    key: []const u8,
    label: []const u8,
    empty_hint: []const u8,
};

const fields = [_]Field{
    .{ .key = "host", .label = "Host", .empty_hint = "127.0.0.1 (默认)" },
    .{ .key = "port", .label = "Port", .empty_hint = "7890 (默认)" },
    .{ .key = "protocol", .label = "Protocol", .empty_hint = "http (默认)" },
    .{ .key = "username", .label = "Username", .empty_hint = "(未设置)" },
    .{ .key = "password", .label = "Password", .empty_hint = "(未设置)" },
};

/// Protocol 从固定选项中选择，不做自由文本编辑。
/// 环境变量代理仅支持这些 URL scheme (TCP/UDP 转发是服务端模式，表达不了)。
const protocol_field = 2;
const protocol_options = [_][]const u8{ "http", "https", "socks5", "socks4" };

/// 焦点区域: 节点列表 / 别名列表 / 右侧详情面板。
const Panel = enum { nodes, aliases, detail };
/// 详情面板内容: 当前配置 (节点列表首行) / 某个节点 / 某条别名。
const DetailTarget = enum { config, node, alias };
const Mode = enum {
    normal,
    edit_field, // 详情面板内编辑单个字段 (文本或协议选项)
    edit_alias_plats, // 别名详情的平台复选框编辑
    add_alias,
    confirm_delete,
    save_node,
    confirm_del_node,
};
const AddStep = enum { platform, name, command };
const StatusKind = enum { info, ok, err };

const max_input_bytes = 160;

/// 终端至少这么宽才启用左右双栏布局。
const wide_min_width = 90;

pub fn run(allocator: std.mem.Allocator) !void {
    var tty = term.Terminal.init() catch {
        output.print("错误: TUI 需要在交互式终端中运行 (当前输入/输出被重定向)\n", .{});
        return;
    };
    defer tty.deinit();

    var app = App{
        .allocator = allocator,
        .tty = &tty,
        .config = Config.ConfigData.init(allocator),
        .aliases = try allocator.alloc(Alias.Entry, 0),
        .groups = try allocator.alloc(Group, 0),
        .nodes = try allocator.alloc(Profile.Entry, 0),
    };
    defer app.deinit();

    app.setStatus(.info, "配置保存在 ~/.proxy/ 目录", .{});
    app.reload();

    var input = term.Input.init(&tty);
    var last_size = tty.size();
    while (app.running) {
        try app.render();
        // 等待按键；空闲时轮询窗口尺寸，缩放后立即重绘自适应
        while (!input.hasBuffered() and !tty.pollInput(200)) {
            const now = tty.size();
            if (now.w != last_size.w or now.h != last_size.h) {
                last_size = now;
                try app.render();
            }
        }
        const key = input.next() catch break;
        try app.handleKey(key);
    }
}

const App = struct {
    allocator: std.mem.Allocator,
    tty: *term.Terminal,
    config: Config.ConfigData,
    aliases: []Alias.Entry,
    groups: []Group,
    nodes: []Profile.Entry,

    frame: std.ArrayList(u8) = .{},
    row: std.ArrayList(u8) = .{},
    row_used: usize = 0,
    // 行拼装缓冲。capture 非空时整行被捕获 (双栏合成/悬浮弹窗用)，否则直接进 frame。
    lb: std.ArrayList(u8) = .{},
    capture: ?*std.ArrayList([]u8) = null,
    w_total: usize = 80,
    iw: usize = 78,

    panel: Panel = .nodes,
    /// 最近聚焦的列表，决定详情面板显示什么
    last_list: Panel = .nodes,
    mode: Mode = .normal,
    running: bool = true,

    /// 节点列表光标。0 = "当前配置" 虚拟行，1.. = nodes[i-1]
    node_cursor: usize = 0,
    node_scroll: usize = 0,
    alias_cursor: usize = 0,
    alias_scroll: usize = 0,
    detail_cursor: usize = 0,

    // 字段编辑。Protocol 走 edit_opt 选项，其余走 edit 文本缓冲。
    edit: std.ArrayList(u8) = .{},
    edit_field: usize = 0,
    edit_opt: usize = 0,

    // 添加别名弹窗。平台为多选: 勾选几个就保存到几个平台。
    add_step: AddStep = .platform,
    add_plat_cursor: usize = 0,
    add_selected: [platforms.len]bool = .{ true, false, false, false },
    add_name: std.ArrayList(u8) = .{},
    add_cmd: std.ArrayList(u8) = .{},

    status_buf: [256]u8 = undefined,
    status_len: usize = 0,
    status_kind: StatusKind = .info,

    fn deinit(self: *App) void {
        self.config.deinit();
        Alias.freeEntries(self.allocator, self.aliases);
        Profile.freeEntries(self.allocator, self.nodes);
        self.allocator.free(self.groups);
        self.frame.deinit(self.allocator);
        self.row.deinit(self.allocator);
        self.lb.deinit(self.allocator);
        self.edit.deinit(self.allocator);
        self.add_name.deinit(self.allocator);
        self.add_cmd.deinit(self.allocator);
    }

    /// 重新加载配置/别名/节点。读取失败时保留旧数据并在状态栏提示。
    fn reload(self: *App) void {
        if (Config.load(self.allocator)) |new_config| {
            self.config.deinit();
            self.config = new_config;
        } else |err| {
            self.setStatus(.err, "读取配置失败: {s}", .{@errorName(err)});
        }

        if (Alias.getAll(self.allocator)) |entries| {
            Alias.freeEntries(self.allocator, self.aliases);
            self.aliases = entries;
        } else |err| {
            self.setStatus(.err, "读取别名失败: {s}", .{@errorName(err)});
        }

        self.rebuildGroups() catch {};

        if (Profile.getAll(self.allocator)) |entries| {
            Profile.freeEntries(self.allocator, self.nodes);
            self.nodes = entries;
        } else |err| {
            self.setStatus(.err, "读取节点失败: {s}", .{@errorName(err)});
        }

        if (self.groups.len == 0) {
            self.alias_cursor = 0;
            self.alias_scroll = 0;
        } else if (self.alias_cursor >= self.groups.len) {
            self.alias_cursor = self.groups.len - 1;
        }
        // 节点光标含虚拟行，上限为 nodes.len
        if (self.node_cursor > self.nodes.len) {
            self.node_cursor = self.nodes.len;
        }
        if (self.detail_cursor >= self.detailFieldCount() and self.detailFieldCount() > 0) {
            self.detail_cursor = self.detailFieldCount() - 1;
        }
    }

    /// 把原始别名记录按 (名称, 命令) 合并成显示分组。
    fn rebuildGroups(self: *App) !void {
        var list: std.ArrayList(Group) = .{};
        errdefer list.deinit(self.allocator);

        for (self.aliases) |e| {
            var target: ?*Group = null;
            for (list.items) |*g| {
                if (std.mem.eql(u8, g.name, e.name) and
                    std.mem.eql(u8, g.command, e.command))
                {
                    target = g;
                    break;
                }
            }
            if (target == null) {
                try list.append(self.allocator, .{ .name = e.name, .command = e.command });
                target = &list.items[list.items.len - 1];
            }
            const g = target.?;
            if (platIndex(e.platform)) |pi| g.plats[pi] = true;

            // 平台标签用 + 连接，如 "linux+macos"；超长静默截断
            if (g.tags_len > 0 and g.tags_len < g.tags.len) {
                g.tags[g.tags_len] = '+';
                g.tags_len += 1;
            }
            const n = @min(e.platform.len, g.tags.len - g.tags_len);
            @memcpy(g.tags[g.tags_len..][0..n], e.platform[0..n]);
            g.tags_len += n;
        }

        self.allocator.free(self.groups);
        self.groups = try list.toOwnedSlice(self.allocator);
    }

    fn setStatus(self: *App, kind: StatusKind, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.status_buf, fmt, args) catch {
            self.status_len = 0;
            self.status_kind = kind;
            return;
        };
        self.status_len = s.len;
        self.status_kind = kind;
    }

    fn fieldValue(self: *const App, idx: usize) []const u8 {
        return switch (idx) {
            0 => self.config.host,
            1 => self.config.port,
            2 => self.config.protocol,
            3 => self.config.username,
            else => self.config.password,
        };
    }

    fn nodeFieldValue(self: *const App, node_idx: usize, field_idx: usize) []const u8 {
        const n = self.nodes[node_idx];
        return switch (field_idx) {
            0 => n.host,
            1 => n.port,
            2 => n.protocol,
            3 => n.username,
            else => n.password,
        };
    }

    fn detailTarget(self: *const App) DetailTarget {
        if (self.last_list == .aliases) return .alias;
        return if (self.node_cursor == 0) .config else .node;
    }

    fn detailFieldCount(self: *const App) usize {
        return switch (self.detailTarget()) {
            .alias => if (self.groups.len == 0) 0 else 3,
            else => fields.len,
        };
    }

    // ------------------------------------------------------------------
    // 按键处理
    // ------------------------------------------------------------------

    fn handleKey(self: *App, key: term.Key) !void {
        switch (self.mode) {
            .normal => try self.handleNormal(key),
            .edit_field => try self.handleEditField(key),
            .edit_alias_plats => try self.handleAliasPlats(key),
            .add_alias => try self.handleAdd(key),
            .confirm_delete => self.handleConfirm(key),
            .save_node => try self.handleSaveNode(key),
            .confirm_del_node => self.handleConfirmDelNode(key),
        }
    }

    fn handleNormal(self: *App, key: term.Key) !void {
        switch (key) {
            .ctrl => |c| if (c == 3) {
                self.running = false;
            },
            .escape => if (self.panel == .detail) {
                self.leaveDetail();
            } else {
                self.running = false;
            },
            .tab => switch (self.panel) {
                .nodes => {
                    self.panel = .aliases;
                    self.last_list = .aliases;
                },
                .aliases => self.panel = .detail,
                .detail => {
                    self.panel = .nodes;
                    self.last_list = .nodes;
                },
            },
            .up => self.moveUp(),
            .down => self.moveDown(),
            .left => if (self.panel == .detail) self.leaveDetail(),
            .right => if (self.panel != .detail) self.enterDetail(),
            .home => switch (self.panel) {
                .nodes => self.node_cursor = 0,
                .aliases => self.alias_cursor = 0,
                .detail => self.detail_cursor = 0,
            },
            .end => switch (self.panel) {
                .nodes => self.node_cursor = self.nodes.len,
                .aliases => if (self.groups.len > 0) {
                    self.alias_cursor = self.groups.len - 1;
                },
                .detail => if (self.detailFieldCount() > 0) {
                    self.detail_cursor = self.detailFieldCount() - 1;
                },
            },
            .enter => switch (self.panel) {
                // 节点列表: 首行进详情编辑当前配置，节点行一键切换
                .nodes => if (self.node_cursor == 0) self.enterDetail() else self.switchNode(),
                .aliases => if (self.groups.len == 0) self.startAdd() else self.enterDetail(),
                .detail => try self.startFieldEdit(),
            },
            .char => |c| switch (c) {
                'q' => self.running = false,
                'j' => self.moveDown(),
                'k' => self.moveUp(),
                'h' => if (self.panel == .detail) self.leaveDetail(),
                'l' => if (self.panel != .detail) self.enterDetail(),
                // a/d 跟随当前列表语境
                'a' => if (self.last_list == .nodes and self.panel != .aliases) {
                    self.startSaveNode();
                } else {
                    self.startAdd();
                },
                's' => self.startSaveNode(),
                'd' => switch (self.panel) {
                    .nodes => self.startDeleteNode(),
                    .aliases => self.startDelete(),
                    .detail => {},
                },
                'r' => {
                    self.setStatus(.ok, "✓ 已重新加载", .{});
                    self.reload();
                },
                else => {},
            },
            else => {},
        }
    }

    fn moveUp(self: *App) void {
        switch (self.panel) {
            .nodes => {
                const total = self.nodes.len + 1;
                self.node_cursor = (self.node_cursor + total - 1) % total;
                self.detail_cursor = 0;
            },
            .aliases => if (self.groups.len > 0) {
                self.alias_cursor =
                    (self.alias_cursor + self.groups.len - 1) % self.groups.len;
                self.detail_cursor = 0;
            },
            .detail => {
                const count = self.detailFieldCount();
                if (count > 0) {
                    self.detail_cursor = (self.detail_cursor + count - 1) % count;
                }
            },
        }
    }

    fn moveDown(self: *App) void {
        switch (self.panel) {
            .nodes => {
                self.node_cursor = (self.node_cursor + 1) % (self.nodes.len + 1);
                self.detail_cursor = 0;
            },
            .aliases => if (self.groups.len > 0) {
                self.alias_cursor = (self.alias_cursor + 1) % self.groups.len;
                self.detail_cursor = 0;
            },
            .detail => {
                const count = self.detailFieldCount();
                if (count > 0) {
                    self.detail_cursor = (self.detail_cursor + 1) % count;
                }
            },
        }
    }

    fn enterDetail(self: *App) void {
        if (self.panel == .nodes or self.panel == .aliases) self.last_list = self.panel;
        if (self.detailTarget() == .alias and self.groups.len == 0) {
            self.setStatus(.info, "暂无别名，按 a 添加", .{});
            return;
        }
        self.panel = .detail;
        self.detail_cursor = 0;
    }

    fn leaveDetail(self: *App) void {
        self.panel = self.last_list;
    }

    // -- 节点操作 ---------------------------------------------------------

    fn switchNode(self: *App) void {
        if (self.nodes.len == 0) {
            self.startSaveNode();
            return;
        }
        const node = self.nodes[self.node_cursor - 1];
        if (std.mem.eql(u8, self.config.node, node.name)) {
            self.setStatus(.info, "已是当前节点: {s}", .{node.name});
            return;
        }
        Profile.switchTo(self.allocator, node.name) catch |err| {
            self.setStatus(.err, "切换失败: {s}", .{@errorName(err)});
            return;
        };
        self.setStatus(.ok, "✓ 已切换到节点 {s}", .{node.name});
        self.reload();
    }

    fn startSaveNode(self: *App) void {
        self.panel = .nodes;
        self.last_list = .nodes;
        self.mode = .save_node;
        self.edit.clearRetainingCapacity();
        // 预填当前节点名，便于快速更新
        self.edit.appendSlice(self.allocator, self.config.node) catch {};
        self.setStatus(.info, "把当前配置保存为节点", .{});
    }

    fn handleSaveNode(self: *App, key: term.Key) !void {
        switch (key) {
            .escape => {
                self.mode = .normal;
                self.setStatus(.info, "已取消", .{});
            },
            .ctrl => |c| switch (c) {
                3 => {
                    self.mode = .normal;
                    self.setStatus(.info, "已取消", .{});
                },
                21 => self.edit.clearRetainingCapacity(),
                else => {},
            },
            .backspace => popCodepoint(&self.edit),
            // 节点名不允许空格
            .char => |c| if (c != ' ') try self.appendCp(&self.edit, c),
            .enter => {
                const name = std.mem.trim(u8, self.edit.items, " \t");
                if (name.len == 0) {
                    self.setStatus(.err, "节点名不能为空", .{});
                    return;
                }
                Profile.saveCurrent(self.allocator, name) catch |err| {
                    self.setStatus(.err, "保存失败: {s}", .{@errorName(err)});
                    return;
                };
                self.mode = .normal;
                self.setStatus(.ok, "✓ 当前配置已保存为节点 {s}", .{name});
                self.reload();
                for (self.nodes, 0..) |n, i| {
                    if (std.mem.eql(u8, n.name, name)) self.node_cursor = i + 1;
                }
            },
            else => {},
        }
    }

    fn startDeleteNode(self: *App) void {
        if (self.node_cursor == 0) {
            self.setStatus(.err, "当前配置不可删除，选中具体节点后再按 d", .{});
            return;
        }
        self.mode = .confirm_del_node;
        const node = self.nodes[self.node_cursor - 1];
        self.setStatus(.err, "删除节点 {s}？按 y 确认", .{node.name});
    }

    fn handleConfirmDelNode(self: *App, key: term.Key) void {
        self.mode = .normal;
        const yes = switch (key) {
            .char => |c| c == 'y' or c == 'Y',
            else => false,
        };
        if (!yes) {
            self.setStatus(.info, "已取消", .{});
            return;
        }
        const node = self.nodes[self.node_cursor - 1];
        Profile.remove(self.allocator, node.name) catch |err| {
            self.setStatus(.err, "删除失败: {s}", .{@errorName(err)});
            return;
        };
        self.setStatus(.ok, "✓ 节点 {s} 已删除", .{node.name});
        self.reload();
    }

    // -- 详情面板字段编辑 --------------------------------------------------

    fn startFieldEdit(self: *App) !void {
        switch (self.detailTarget()) {
            .config, .node => {
                self.edit_field = self.detail_cursor;
                const cur = if (self.detailTarget() == .config)
                    self.fieldValue(self.detail_cursor)
                else
                    self.nodeFieldValue(self.node_cursor - 1, self.detail_cursor);

                if (self.detail_cursor == protocol_field) {
                    self.edit_opt = 0;
                    for (protocol_options, 0..) |opt, oi| {
                        if (std.mem.eql(u8, cur, opt)) self.edit_opt = oi;
                    }
                    self.mode = .edit_field;
                    self.setStatus(.info, "←→ 切换协议，Enter 保存", .{});
                    return;
                }
                self.edit.clearRetainingCapacity();
                try self.edit.appendSlice(self.allocator, cur);
                self.mode = .edit_field;
                self.setStatus(.info, "编辑 {s}，留空保存则恢复默认", .{fields[self.detail_cursor].label});
            },
            .alias => {
                if (self.groups.len == 0) {
                    self.startAdd();
                    return;
                }
                const g = self.groups[self.alias_cursor];
                switch (self.detail_cursor) {
                    0, 1 => {
                        self.edit_field = self.detail_cursor;
                        self.edit.clearRetainingCapacity();
                        try self.edit.appendSlice(
                            self.allocator,
                            if (self.detail_cursor == 0) g.name else g.command,
                        );
                        self.mode = .edit_field;
                        self.setStatus(.info, "编辑别名{s}", .{
                            if (self.detail_cursor == 0) @as([]const u8, "名称") else "命令",
                        });
                    },
                    else => {
                        self.add_selected = g.plats;
                        if (self.selectedCount() == 0) self.add_selected[0] = true;
                        self.add_plat_cursor = 0;
                        for (self.add_selected, 0..) |sel, i| {
                            if (sel) {
                                self.add_plat_cursor = i;
                                break;
                            }
                        }
                        self.mode = .edit_alias_plats;
                        self.setStatus(.info, "空格 勾选平台，Enter 保存", .{});
                    },
                }
            },
        }
    }

    fn handleEditField(self: *App, key: term.Key) !void {
        const target = self.detailTarget();
        if (target != .alias and self.edit_field == protocol_field) {
            return self.handleEditProtocol(key);
        }
        switch (key) {
            .escape => {
                self.mode = .normal;
                self.setStatus(.info, "已取消", .{});
            },
            .enter => try self.commitFieldEdit(),
            .backspace => popCodepoint(&self.edit),
            .char => |c| {
                // 别名名称按空格分词解析，不允许空格
                if (target == .alias and self.edit_field == 0 and c == ' ') return;
                try self.appendCp(&self.edit, c);
            },
            .ctrl => |c| switch (c) {
                3 => {
                    self.mode = .normal;
                    self.setStatus(.info, "已取消", .{});
                },
                21 => self.edit.clearRetainingCapacity(), // Ctrl+U 清空
                else => {},
            },
            else => {},
        }
    }

    fn handleEditProtocol(self: *App, key: term.Key) !void {
        switch (key) {
            .escape => {
                self.mode = .normal;
                self.setStatus(.info, "已取消", .{});
            },
            .ctrl => |c| if (c == 3) {
                self.mode = .normal;
                self.setStatus(.info, "已取消", .{});
            },
            .left => self.edit_opt =
                (self.edit_opt + protocol_options.len - 1) % protocol_options.len,
            .right, .tab => self.edit_opt = (self.edit_opt + 1) % protocol_options.len,
            .char => |c| switch (c) {
                'h' => self.edit_opt =
                    (self.edit_opt + protocol_options.len - 1) % protocol_options.len,
                'l', ' ' => self.edit_opt = (self.edit_opt + 1) % protocol_options.len,
                else => {},
            },
            .enter => {
                const value = protocol_options[self.edit_opt];
                switch (self.detailTarget()) {
                    .node => {
                        const node = self.nodes[self.node_cursor - 1];
                        Profile.update(self.allocator, node.name, "protocol", value) catch |err| {
                            self.mode = .normal;
                            self.setStatus(.err, "保存失败: {s}", .{@errorName(err)});
                            return;
                        };
                        self.setStatus(.ok, "✓ 节点 {s} 协议已设为 {s}", .{ node.name, value });
                    },
                    else => {
                        Config.set(self.allocator, "protocol", value) catch |err| {
                            self.mode = .normal;
                            self.setStatus(.err, "保存失败: {s}", .{@errorName(err)});
                            return;
                        };
                        self.setStatus(.ok, "✓ Protocol 已设为 {s}", .{value});
                    },
                }
                self.mode = .normal;
                self.reload();
            },
            else => {},
        }
    }

    fn commitFieldEdit(self: *App) !void {
        const value = std.mem.trim(u8, self.edit.items, " \t");

        switch (self.detailTarget()) {
            .config, .node => {
                const f = fields[self.edit_field];
                if (std.mem.eql(u8, f.key, "port") and value.len > 0) {
                    const port = std.fmt.parseInt(u16, value, 10) catch 0;
                    if (port == 0) {
                        self.setStatus(.err, "端口必须是 1-65535 的数字", .{});
                        return;
                    }
                }
                if (self.detailTarget() == .node) {
                    const node = self.nodes[self.node_cursor - 1];
                    Profile.update(self.allocator, node.name, f.key, value) catch |err| {
                        self.mode = .normal;
                        self.setStatus(.err, "保存失败: {s}", .{@errorName(err)});
                        return;
                    };
                    self.setStatus(.ok, "✓ 节点 {s} 的 {s} 已更新", .{ node.name, f.label });
                } else {
                    Config.set(self.allocator, f.key, value) catch |err| {
                        self.mode = .normal;
                        self.setStatus(.err, "保存失败: {s}", .{@errorName(err)});
                        return;
                    };
                    if (value.len > 0) {
                        self.setStatus(.ok, "✓ {s} 已更新", .{f.label});
                    } else {
                        self.setStatus(.ok, "✓ {s} 已恢复默认", .{f.label});
                    }
                }
                self.mode = .normal;
                self.reload();
            },
            .alias => {
                if (value.len == 0) {
                    self.setStatus(.err, "不能为空", .{});
                    return;
                }
                const g = self.groups[self.alias_cursor];
                const new_name = if (self.edit_field == 0) value else g.name;
                const new_cmd = if (self.edit_field == 1) value else g.command;
                try self.rewriteAliasGroup(g, new_name, new_cmd, g.plats);
            },
        }
    }

    fn handleAliasPlats(self: *App, key: term.Key) !void {
        switch (key) {
            .escape => {
                self.mode = .normal;
                self.setStatus(.info, "已取消", .{});
            },
            .ctrl => |c| if (c == 3) {
                self.mode = .normal;
                self.setStatus(.info, "已取消", .{});
            },
            .left => self.add_plat_cursor =
                (self.add_plat_cursor + platforms.len - 1) % platforms.len,
            .right => self.add_plat_cursor = (self.add_plat_cursor + 1) % platforms.len,
            .char => |c| switch (c) {
                'h' => self.add_plat_cursor =
                    (self.add_plat_cursor + platforms.len - 1) % platforms.len,
                'l' => self.add_plat_cursor = (self.add_plat_cursor + 1) % platforms.len,
                ' ' => self.add_selected[self.add_plat_cursor] =
                    !self.add_selected[self.add_plat_cursor],
                else => {},
            },
            .enter => {
                if (self.selectedCount() == 0) {
                    self.setStatus(.err, "至少勾选一个平台", .{});
                    return;
                }
                const g = self.groups[self.alias_cursor];
                try self.rewriteAliasGroup(g, g.name, g.command, self.add_selected);
            },
            else => {},
        }
    }

    /// 整组重写别名: 删除旧记录，按 plats 写入新的 name/command。
    fn rewriteAliasGroup(
        self: *App,
        g: Group,
        new_name: []const u8,
        new_cmd: []const u8,
        plats: [platforms.len]bool,
    ) !void {
        // name/cmd 可能借用即将随 reload 释放的内存，先拷贝
        var name_buf: [max_input_bytes + 8]u8 = undefined;
        var cmd_buf: [max_input_bytes + 8]u8 = undefined;
        if (new_name.len > name_buf.len or new_cmd.len > cmd_buf.len) return error.ValueTooLong;
        @memcpy(name_buf[0..new_name.len], new_name);
        @memcpy(cmd_buf[0..new_cmd.len], new_cmd);
        const name = name_buf[0..new_name.len];
        const command = cmd_buf[0..new_cmd.len];

        var sel = plats;
        var any = false;
        for (sel) |s| any = any or s;
        if (!any) sel[0] = true;
        // 勾选了 all，或三个系统全选时，归并为一条 all 记录
        if (sel[0] or (sel[1] and sel[2] and sel[3])) {
            sel = .{ true, false, false, false };
        }

        for (self.aliases) |e| {
            if (std.mem.eql(u8, e.name, g.name) and
                std.mem.eql(u8, e.command, g.command))
            {
                Alias.remove(self.allocator, e.platform, e.name) catch {};
            }
        }
        for (platforms, 0..) |p, i| {
            if (!sel[i]) continue;
            Alias.add(self.allocator, p, name, command) catch |err| {
                self.mode = .normal;
                self.setStatus(.err, "保存失败: {s}", .{@errorName(err)});
                self.reload();
                return;
            };
        }

        self.mode = .normal;
        self.setStatus(.ok, "✓ 别名 {s} 已更新", .{name});
        self.reload();
        for (self.groups, 0..) |gg, i| {
            if (std.mem.eql(u8, gg.name, name) and std.mem.eql(u8, gg.command, command)) {
                self.alias_cursor = i;
                break;
            }
        }
    }

    // -- 添加别名弹窗 ------------------------------------------------------

    fn startAdd(self: *App) void {
        self.panel = .aliases;
        self.last_list = .aliases;
        self.mode = .add_alias;
        self.add_step = .platform;
        self.add_plat_cursor = 0;
        self.add_selected = .{ true, false, false, false };
        self.add_name.clearRetainingCapacity();
        self.add_cmd.clearRetainingCapacity();
        self.setStatus(.info, "添加别名: ←→ 移动，空格 勾选平台 (可多选)", .{});
    }

    fn handleAdd(self: *App, key: term.Key) !void {
        switch (key) {
            .ctrl => |c| if (c == 3) self.cancelAdd(),
            .escape => switch (self.add_step) {
                .platform => self.cancelAdd(),
                .name => self.add_step = .platform,
                .command => self.add_step = .name,
            },
            .left => if (self.add_step == .platform) {
                self.add_plat_cursor = (self.add_plat_cursor + platforms.len - 1) % platforms.len;
            },
            .right => if (self.add_step == .platform) {
                self.add_plat_cursor = (self.add_plat_cursor + 1) % platforms.len;
            },
            .backspace => switch (self.add_step) {
                .platform => {},
                .name => popCodepoint(&self.add_name),
                .command => popCodepoint(&self.add_cmd),
            },
            .char => |c| switch (self.add_step) {
                .platform => switch (c) {
                    'h' => self.add_plat_cursor =
                        (self.add_plat_cursor + platforms.len - 1) % platforms.len,
                    'l' => self.add_plat_cursor = (self.add_plat_cursor + 1) % platforms.len,
                    ' ' => self.add_selected[self.add_plat_cursor] =
                        !self.add_selected[self.add_plat_cursor],
                    else => {},
                },
                // 别名按空格分词解析，名称里不允许空格
                .name => if (c != ' ') try self.appendCp(&self.add_name, c),
                .command => try self.appendCp(&self.add_cmd, c),
            },
            .enter => switch (self.add_step) {
                .platform => {
                    if (self.selectedCount() == 0) {
                        self.setStatus(.err, "至少勾选一个平台 (空格勾选)", .{});
                    } else {
                        self.add_step = .name;
                    }
                },
                .name => {
                    if (std.mem.trim(u8, self.add_name.items, " \t").len == 0) {
                        self.setStatus(.err, "别名名称不能为空", .{});
                    } else {
                        self.add_step = .command;
                    }
                },
                .command => try self.commitAdd(),
            },
            else => {},
        }
    }

    fn cancelAdd(self: *App) void {
        self.mode = .normal;
        self.setStatus(.info, "已取消", .{});
    }

    fn selectedCount(self: *const App) usize {
        var n: usize = 0;
        for (self.add_selected) |s| {
            if (s) n += 1;
        }
        return n;
    }

    fn commitAdd(self: *App) !void {
        const name = std.mem.trim(u8, self.add_name.items, " \t");
        const command = std.mem.trim(u8, self.add_cmd.items, " \t");
        if (name.len == 0) {
            self.add_step = .name;
            self.setStatus(.err, "别名名称不能为空", .{});
            return;
        }
        if (command.len == 0) {
            self.setStatus(.err, "命令不能为空", .{});
            return;
        }
        if (self.selectedCount() == 0) {
            self.add_step = .platform;
            self.setStatus(.err, "至少勾选一个平台 (空格勾选)", .{});
            return;
        }

        // 勾选了 all，或三个系统全选时，归并为一条 all 记录
        var selected = self.add_selected;
        if (selected[0] or (selected[1] and selected[2] and selected[3])) {
            selected = .{ true, false, false, false };
        }

        // 保存到每个勾选的平台，并拼出平台列表用于状态提示
        var joined_buf: [64]u8 = undefined;
        var joined_len: usize = 0;
        for (platforms, 0..) |platform, i| {
            if (!selected[i]) continue;
            Alias.add(self.allocator, platform, name, command) catch |err| {
                self.setStatus(.err, "保存到 {s} 失败: {s}", .{ platform, @errorName(err) });
                return;
            };
            if (joined_len > 0 and joined_len + 1 <= joined_buf.len) {
                joined_buf[joined_len] = '+';
                joined_len += 1;
            }
            if (joined_len + platform.len <= joined_buf.len) {
                @memcpy(joined_buf[joined_len..][0..platform.len], platform);
                joined_len += platform.len;
            }
        }

        self.mode = .normal;
        self.setStatus(.ok, "✓ 别名 {s} 已保存到 {s}", .{ name, joined_buf[0..joined_len] });
        self.reload();

        // 光标跳到刚保存的分组
        for (self.groups, 0..) |g, i| {
            if (std.mem.eql(u8, g.name, name) and std.mem.eql(u8, g.command, command)) {
                self.alias_cursor = i;
                break;
            }
        }
    }

    // -- 删除别名 ---------------------------------------------------------

    fn startDelete(self: *App) void {
        if (self.groups.len == 0) {
            self.setStatus(.err, "没有可删除的别名", .{});
            return;
        }
        self.mode = .confirm_delete;
        const g = self.groups[self.alias_cursor];
        self.setStatus(.err, "删除别名 {s} ({s})？按 y 确认", .{ g.name, g.tags[0..g.tags_len] });
    }

    fn handleConfirm(self: *App, key: term.Key) void {
        self.mode = .normal;
        const yes = switch (key) {
            .char => |c| c == 'y' or c == 'Y',
            else => false,
        };
        if (!yes) {
            self.setStatus(.info, "已取消", .{});
            return;
        }

        // 整组删除: 该别名在所有平台上的同命令记录一并移除
        const g = self.groups[self.alias_cursor];
        for (self.aliases) |e| {
            if (std.mem.eql(u8, e.name, g.name) and
                std.mem.eql(u8, e.command, g.command))
            {
                Alias.remove(self.allocator, e.platform, e.name) catch |err| {
                    self.setStatus(.err, "删除失败: {s}", .{@errorName(err)});
                    return;
                };
            }
        }
        self.setStatus(.ok, "✓ 别名 {s} 已删除", .{g.name});
        self.reload();
    }

    // -- 输入缓冲工具 ------------------------------------------------------

    fn appendCp(self: *App, list: *std.ArrayList(u8), cp: u21) !void {
        if (list.items.len >= max_input_bytes) return;
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &tmp) catch return;
        try list.appendSlice(self.allocator, tmp[0..n]);
    }

    // ------------------------------------------------------------------
    // 渲染: 每帧整屏重画进 frame 缓冲，最后一次性写出，避免闪烁。
    // ------------------------------------------------------------------

    fn emit(self: *App, s: []const u8) !void {
        try self.frame.appendSlice(self.allocator, s);
    }

    fn render(self: *App) !void {
        try self.renderFrame(self.tty.size());
        self.tty.write(self.frame.items);
    }

    /// 构建一帧完整画面到 frame 缓冲。与终端解耦，便于单元测试。
    /// 画面始终撑满整个终端: 宽屏走左右双栏，窄屏走上下堆叠。
    fn renderFrame(self: *App, size: term.Size) !void {
        self.frame.clearRetainingCapacity();
        try self.emit("\x1b[H");

        if (size.w < 44 or size.h < 16) {
            try self.emit(A.yellow ++ " 终端窗口太小，请放大到至少 44x16" ++ A.reset ++ EOL);
            try self.emit("\x1b[J");
            return;
        }

        self.setPanelWidth(size.w);
        if (size.w >= wide_min_width) {
            try self.renderWide(size);
        } else {
            try self.renderNarrow(size);
        }
    }

    fn setPanelWidth(self: *App, w: usize) void {
        self.w_total = w;
        self.iw = w - 2;
    }

    /// 标题栏 + 当前代理地址预览 + 空行，共 3 行。
    fn renderHeader(self: *App) !void {
        try self.emit(" " ++ A.bold ++ A.bcyan ++ "PROXY" ++ A.reset ++
            A.dim ++ " · 跨平台代理配置管理" ++ A.reset ++ EOL);
        var url_buf: [320]u8 = undefined;
        const url = self.buildDisplayUrl(&url_buf);
        try self.emit(" " ++ A.dim ++ "代理地址 " ++ A.reset ++ A.green);
        try self.emit(url[0..term.truncateBytes(url, self.w_total -| 11)]);
        if (self.config.node.len > 0) {
            try self.emit(A.reset ++ A.dim ++ " · 节点 ");
            try self.emit(self.config.node[0..term.truncateBytes(self.config.node, 16)]);
        }
        try self.emit(A.reset ++ EOL ++ EOL);
    }

    /// 窄终端: 上下堆叠 (节点 → 别名 → 详情)。别名弹窗打开时弹窗即编辑器，
    /// 隐藏节点与详情；高度紧张 (<22) 时隐藏节点列表。
    fn renderNarrow(self: *App, size: term.Size) !void {
        try self.renderHeader();

        if (self.mode == .add_alias) {
            // 3 头部 + (2+avail) 别名 + 5 弹窗 + 2 状态/快捷键 = h
            const avail = if (size.h > 12) size.h - 12 else 1;
            try self.renderAliasList(avail);
            try self.renderAddModal();
        } else {
            var nh: usize = 0;
            if (size.h >= 22) {
                const node_rows: usize = @min(self.nodes.len + 1, 3);
                try self.renderNodeList(node_rows);
                nh = node_rows + 2;
            }
            // 3 头部 + nh 节点 + (2+avail) 别名 + 7 详情 + 2 状态/快捷键 = h
            const fixed = 14 + nh;
            const avail = if (size.h > fixed) size.h - fixed else 1;
            try self.renderAliasList(avail);
            try self.renderDetail(5);
        }

        try self.renderStatus();
        try self.renderFooter();
        try self.emit("\x1b[J");
    }

    /// 宽终端: 左栏列表 (节点 + 别名)，右栏详情面板独占整列，
    /// 添加别名以居中悬浮弹窗绘制在最上层。
    fn renderWide(self: *App, size: term.Size) !void {
        try self.renderHeader();

        const lw: usize = 32;
        const rw = size.w - lw - 1;
        const ch = size.h - 5; // 头部 3 + 状态栏 1 + 底部快捷键 1

        var left: std.ArrayList([]u8) = .{};
        defer freeLines(self.allocator, &left);
        var right: std.ArrayList([]u8) = .{};
        defer freeLines(self.allocator, &right);

        // 左栏: 节点列表 + 别名列表填满剩余高度
        self.capture = &left;
        self.setPanelWidth(lw);
        const total: usize = self.nodes.len + 1;
        var node_rows: usize = @min(total, 8);
        var nh: usize = node_rows + 2;
        if (ch < nh + 3) {
            // 别名列表至少 1 行
            nh = if (ch > 6) ch - 3 else 3;
            node_rows = nh - 2;
        }
        try self.renderNodeList(node_rows);
        try self.renderAliasList(ch - nh - 2);

        // 右栏: 详情面板独占整列
        self.capture = &right;
        self.setPanelWidth(rw);
        try self.renderDetail(ch - 2);

        self.capture = null;
        self.setPanelWidth(size.w);

        // 逐行合成双栏。行宽恰好为终端宽度，行尾不再加 \x1b[K，
        // 避免部分终端在换行待定状态下清掉最后一列。
        var r: usize = 0;
        while (r < ch) : (r += 1) {
            if (r < left.items.len) {
                try self.emit(left.items[r]);
            } else {
                var i: usize = 0;
                while (i < lw) : (i += 1) try self.emit(" ");
            }
            try self.emit(" ");
            if (r < right.items.len) try self.emit(right.items[r]);
            try self.emit("\r\n");
        }

        try self.renderStatus();
        try self.renderFooter();
        try self.emit("\x1b[J");

        if (self.mode == .add_alias) try self.renderModalOverlay(size);
    }

    /// 把弹窗按行定位绘制到画面中央 (在整帧之后输出，覆盖在最上层)。
    fn renderModalOverlay(self: *App, size: term.Size) !void {
        var lines: std.ArrayList([]u8) = .{};
        defer freeLines(self.allocator, &lines);

        const mw = @min(size.w - 8, 64);
        self.capture = &lines;
        self.setPanelWidth(mw);
        try self.renderAddModal();
        self.capture = null;
        self.setPanelWidth(size.w);

        const mh = lines.items.len;
        const top = (size.h -| mh) / 2 + 1;
        const col = (size.w -| mw) / 2 + 1;
        for (lines.items, 0..) |line, i| {
            var pos_buf: [24]u8 = undefined;
            const pos = std.fmt.bufPrint(&pos_buf, "\x1b[{d};{d}H", .{ top + i, col }) catch continue;
            try self.emit(pos);
            try self.emit(line);
        }
    }

    fn buildDisplayUrl(self: *const App, buf: []u8) []const u8 {
        const c = &self.config;
        const proto = if (c.protocol.len > 0) c.protocol else "http";
        const host = if (c.host.len > 0) c.host else "127.0.0.1";
        const port = if (c.port.len > 0) c.port else "7890";

        if (c.username.len > 0 and c.password.len > 0) {
            return std.fmt.bufPrint(buf, "{s}://{s}:***@{s}:{s}", .{ proto, c.username, host, port }) catch "…";
        }
        if (c.username.len > 0) {
            return std.fmt.bufPrint(buf, "{s}://{s}@{s}:{s}", .{ proto, c.username, host, port }) catch "…";
        }
        return std.fmt.bufPrint(buf, "{s}://{s}:{s}", .{ proto, host, port }) catch "…";
    }

    // -- 左侧列表 ----------------------------------------------------------

    /// 节点列表: 首行为 "当前配置" 虚拟项，之后是已保存节点。
    fn renderNodeList(self: *App, rows: usize) !void {
        const active = self.panel == .nodes and self.mode != .add_alias;
        const total = self.nodes.len + 1;

        try self.boxTop("节点", active);

        if (self.node_cursor < self.node_scroll) {
            self.node_scroll = self.node_cursor;
        }
        if (self.node_cursor >= self.node_scroll + rows) {
            self.node_scroll = self.node_cursor + 1 - rows;
        }
        if (total <= rows) {
            self.node_scroll = 0;
        } else if (self.node_scroll + rows > total) {
            self.node_scroll = total - rows;
        }

        var r: usize = 0;
        while (r < rows) : (r += 1) {
            const idx = self.node_scroll + r;
            self.rowBegin();

            if (idx == 0) {
                const selected = active and self.node_cursor == 0;
                if (selected) try self.rowRaw(A.rev);
                try self.rowTxt(if (selected) " ▸ " else "   ");
                if (!selected) {
                    try self.rowRaw(if (self.config.node.len == 0) A.green else A.dim);
                }
                try self.rowTxt(if (self.config.node.len == 0) "● " else "○ ");
                if (!selected) try self.rowRaw(if (self.config.node.len == 0) A.reset ++ A.bwhite else A.reset);
                try self.rowTxt("当前配置");
            } else if (idx < total) {
                const node = self.nodes[idx - 1];
                const selected = active and idx == self.node_cursor;
                const deleting = selected and self.mode == .confirm_del_node;
                const current = std.mem.eql(u8, self.config.node, node.name);

                if (deleting) {
                    try self.rowRaw(A.rev ++ A.bred);
                } else if (selected) {
                    try self.rowRaw(A.rev);
                }
                try self.rowTxt(if (selected) " ▸ " else "   ");
                if (!selected) {
                    try self.rowRaw(if (current) A.green else A.bwhite);
                }
                try self.rowTxt(if (current) "● " else "  ");
                try self.rowTxt(node.name);
                if (!selected) try self.rowRaw(A.reset);
                try self.rowTxt(" ");
                try self.rowPadTo(16);
                if (!selected) try self.rowRaw(A.dim);
                // 列表空间有限只显示 host:port，完整信息在右侧详情
                var addr_buf: [128]u8 = undefined;
                const addr = std.fmt.bufPrint(&addr_buf, "{s}:{s}", .{
                    if (node.host.len > 0) node.host else "127.0.0.1",
                    if (node.port.len > 0) node.port else "7890",
                }) catch "";
                try self.rowTxt(addr);
                if (!selected) try self.rowRaw(A.reset);
            }
            try self.rowEnd(active);
        }

        try self.boxBottom(active);
    }

    fn renderAliasList(self: *App, rows: usize) !void {
        const active = self.panel == .aliases and self.mode != .add_alias;

        var title_buf: [64]u8 = undefined;
        const title = if (self.groups.len == 0)
            "别名"
        else
            std.fmt.bufPrint(&title_buf, "别名 {d}/{d}", .{
                self.alias_cursor + 1, self.groups.len,
            }) catch "别名";
        try self.boxTop(title, active);

        if (self.alias_cursor < self.alias_scroll) {
            self.alias_scroll = self.alias_cursor;
        }
        if (self.groups.len > 0 and self.alias_cursor >= self.alias_scroll + rows) {
            self.alias_scroll = self.alias_cursor + 1 - rows;
        }
        if (self.groups.len <= rows) {
            self.alias_scroll = 0;
        } else if (self.alias_scroll + rows > self.groups.len) {
            self.alias_scroll = self.groups.len - rows;
        }

        // 名称列按内容对齐
        var name_w: usize = 2;
        for (self.groups) |g| {
            name_w = @max(name_w, term.strWidth(g.name));
        }
        name_w = @min(name_w, 14);

        var r: usize = 0;
        while (r < rows) : (r += 1) {
            const idx = self.alias_scroll + r;
            self.rowBegin();

            if (self.groups.len == 0) {
                if (r == 0) {
                    try self.rowRaw(A.dim);
                    try self.rowTxt("   (暂无别名，按 a 添加)");
                }
            } else if (idx < self.groups.len) {
                const g = self.groups[idx];
                const selected = active and idx == self.alias_cursor;
                const deleting = selected and self.mode == .confirm_delete;

                if (deleting) {
                    try self.rowRaw(A.rev ++ A.bred);
                } else if (selected) {
                    try self.rowRaw(A.rev);
                }
                try self.rowTxt(if (selected) " ▸ " else "   ");

                const name_cut = term.truncateBytes(g.name, name_w);
                if (!selected) try self.rowRaw(A.bwhite);
                try self.rowTxt(g.name[0..name_cut]);
                if (!selected) try self.rowRaw(A.reset);
                try self.rowTxt(" ");
                try self.rowPadTo(3 + name_w + 1);
                if (!selected) try self.rowRaw(A.yellow);
                try self.rowTxt("[");
                try self.rowTxt(g.tags[0..g.tags_len]);
                try self.rowTxt("]");
                if (!selected) try self.rowRaw(A.reset);
            }
            try self.rowEnd(active);
        }

        try self.boxBottom(active);
    }

    // -- 右侧详情面板 ------------------------------------------------------

    /// 详情面板: 内容随最近聚焦的列表与选中项切换。rows 为内容行数。
    fn renderDetail(self: *App, rows: usize) !void {
        const active = self.panel == .detail and self.mode != .add_alias;
        const target = self.detailTarget();

        var title_buf: [96]u8 = undefined;
        const title: []const u8 = switch (target) {
            .config => "配置 · 当前生效",
            .node => std.fmt.bufPrint(&title_buf, "节点 · {s}", .{
                self.nodes[self.node_cursor - 1].name,
            }) catch "节点",
            .alias => if (self.groups.len == 0)
                "别名"
            else
                std.fmt.bufPrint(&title_buf, "别名 · {s}", .{
                    self.groups[self.alias_cursor].name,
                }) catch "别名",
        };
        try self.boxTop(title, active);

        var used: usize = 0;
        switch (target) {
            .config => {
                for (fields, 0..) |f, i| {
                    if (used >= rows) break;
                    try self.detailFieldRow(f, self.fieldValue(i), i, active);
                    used += 1;
                }
            },
            .node => {
                for (fields, 0..) |f, i| {
                    if (used >= rows) break;
                    try self.detailFieldRow(f, self.nodeFieldValue(self.node_cursor - 1, i), i, active);
                    used += 1;
                }
            },
            .alias => {
                if (self.groups.len == 0) {
                    self.rowBegin();
                    try self.rowRaw(A.dim);
                    try self.rowTxt("   (暂无别名，按 a 添加)");
                    try self.rowEnd(active);
                    used = 1;
                } else {
                    const g = self.groups[self.alias_cursor];
                    try self.aliasTextRow(0, "名称", g.name, active);
                    try self.aliasTextRow(1, "命令", g.command, active);
                    try self.aliasPlatsRow(2, g, active);
                    used = 3;
                }
            },
        }

        // 空间富余时在底部给一行操作提示
        var r: usize = used;
        while (r < rows) : (r += 1) {
            self.rowBegin();
            if (r == rows - 1 and rows > used + 1) {
                try self.rowRaw(A.dim);
                switch (target) {
                    .config => try self.rowTxt("   Enter 编辑字段 · s 保存为节点"),
                    .node => try self.rowTxt("   Enter 编辑字段 · 列表上 Enter 切换到此节点"),
                    .alias => try self.rowTxt("   Enter 编辑字段 · 平台行空格勾选"),
                }
            }
            try self.rowEnd(active);
        }

        try self.boxBottom(active);
    }

    /// 配置/节点详情的单个字段行 (含行内编辑与协议选项渲染)。
    fn detailFieldRow(self: *App, f: Field, value: []const u8, i: usize, active: bool) !void {
        const selected = active and self.detail_cursor == i;
        const editing = self.panel == .detail and self.mode == .edit_field and
            self.edit_field == i;

        self.rowBegin();
        if (selected and !editing) try self.rowRaw(A.rev);
        try self.rowTxt(if (selected) " ▸ " else "   ");
        try self.rowTxt(f.label);
        try self.rowPadTo(14);

        if (editing and i == protocol_field) {
            // 协议选项: 空间够则平铺，不够退化为紧凑切换器，永不破版
            var need: usize = protocol_options.len - 1;
            for (protocol_options) |opt| need += opt.len;
            if (self.iw -| self.row_used >= need) {
                for (protocol_options, 0..) |opt, oi| {
                    if (oi > 0) try self.rowTxt(" ");
                    if (oi == self.edit_opt) {
                        try self.rowRaw(A.rev);
                    } else {
                        try self.rowRaw(A.dim);
                    }
                    try self.rowTxt(opt);
                    try self.rowRaw(A.reset);
                }
            } else {
                try self.optionCycler(
                    protocol_options[self.edit_opt],
                    self.edit_opt,
                    protocol_options.len,
                );
            }
        } else if (editing) {
            try self.rowRaw(A.yellow);
            const room = self.iw -| self.row_used -| 1;
            try self.rowTxt(tailFit(self.edit.items, room));
            // 块状光标
            try self.rowRaw(A.reset ++ A.rev);
            try self.rowTxt(" ");
            try self.rowRaw(A.reset);
        } else {
            if (value.len == 0) {
                if (!selected) try self.rowRaw(A.dim);
                try self.rowTxt(f.empty_hint);
            } else if (i == 4) {
                try self.rowTxt("••••••");
            } else {
                if (!selected) try self.rowRaw(A.bwhite);
                try self.rowTxt(value);
            }
        }
        try self.rowEnd(active);
    }

    /// 别名详情的文本字段行 (名称/命令)。
    fn aliasTextRow(self: *App, idx: usize, label: []const u8, value: []const u8, active: bool) !void {
        const selected = active and self.detail_cursor == idx;
        const editing = self.panel == .detail and self.mode == .edit_field and
            self.edit_field == idx;

        self.rowBegin();
        if (selected and !editing) try self.rowRaw(A.rev);
        try self.rowTxt(if (selected) " ▸ " else "   ");
        try self.rowTxt(label);
        try self.rowPadTo(14);

        if (editing) {
            try self.rowRaw(A.yellow);
            const room = self.iw -| self.row_used -| 1;
            try self.rowTxt(tailFit(self.edit.items, room));
            try self.rowRaw(A.reset ++ A.rev);
            try self.rowTxt(" ");
            try self.rowRaw(A.reset);
        } else {
            if (!selected) try self.rowRaw(A.bwhite);
            try self.rowTxt(value);
        }
        try self.rowEnd(active);
    }

    /// 别名详情的平台行: 编辑时为复选框，平时显示标签。
    fn aliasPlatsRow(self: *App, idx: usize, g: Group, active: bool) !void {
        const selected = active and self.detail_cursor == idx;
        const editing = self.mode == .edit_alias_plats;

        self.rowBegin();
        if (selected and !editing) try self.rowRaw(A.rev);
        try self.rowTxt(if (selected) " ▸ " else "   ");
        try self.rowTxt("平台");
        try self.rowPadTo(14);

        if (editing) {
            // 空间够则平铺全部复选框，不够退化为逐项切换器
            var need: usize = (platforms.len - 1) * 2;
            for (platforms) |p| need += 4 + p.len;
            if (self.iw -| self.row_used >= need) {
                for (platforms, 0..) |p, i| {
                    const focused = i == self.add_plat_cursor;
                    const checked = self.add_selected[i];
                    if (focused) {
                        try self.rowRaw(A.rev);
                    } else if (checked) {
                        try self.rowRaw(A.green);
                    } else {
                        try self.rowRaw(A.dim);
                    }
                    try self.rowTxt(if (checked) "[✓] " else "[ ] ");
                    try self.rowTxt(p);
                    try self.rowRaw(A.reset);
                    try self.rowTxt("  ");
                }
            } else {
                var label_buf: [40]u8 = undefined;
                const label = std.fmt.bufPrint(&label_buf, "{s} {s}", .{
                    if (self.add_selected[self.add_plat_cursor]) "[✓]" else "[ ]",
                    platforms[self.add_plat_cursor],
                }) catch platforms[self.add_plat_cursor];
                try self.optionCycler(label, self.add_plat_cursor, platforms.len);
            }
        } else {
            if (!selected) try self.rowRaw(A.yellow);
            try self.rowTxt("[");
            try self.rowTxt(g.tags[0..g.tags_len]);
            try self.rowTxt("]");
        }
        try self.rowEnd(active);
    }

    // -- 添加别名弹窗 ------------------------------------------------------

    fn renderAddModal(self: *App) !void {
        try self.boxTop("添加别名", true);

        // 平台多选行: 焦点时显示全部复选框，否则只列出已勾选的
        self.rowBegin();
        const on_platform = self.add_step == .platform;
        try self.rowTxt(if (on_platform) " ▸ " else "   ");
        try self.rowTxt("平台");
        try self.rowPadTo(10);
        if (on_platform) {
            var need: usize = (platforms.len - 1) * 2;
            for (platforms) |p| need += 4 + p.len;
            if (self.iw -| self.row_used >= need) {
                for (platforms, 0..) |p, i| {
                    const focused = i == self.add_plat_cursor;
                    const checked = self.add_selected[i];
                    if (focused) {
                        try self.rowRaw(A.rev);
                    } else if (checked) {
                        try self.rowRaw(A.green);
                    } else {
                        try self.rowRaw(A.dim);
                    }
                    try self.rowTxt(if (checked) "[✓] " else "[ ] ");
                    try self.rowTxt(p);
                    try self.rowRaw(A.reset);
                    try self.rowTxt("  ");
                }
            } else {
                var label_buf: [40]u8 = undefined;
                const label = std.fmt.bufPrint(&label_buf, "{s} {s}", .{
                    if (self.add_selected[self.add_plat_cursor]) "[✓]" else "[ ]",
                    platforms[self.add_plat_cursor],
                }) catch platforms[self.add_plat_cursor];
                try self.optionCycler(label, self.add_plat_cursor, platforms.len);
                try self.rowRaw(A.dim);
                var cnt_buf: [24]u8 = undefined;
                const cnt = std.fmt.bufPrint(&cnt_buf, "  已选 {d}", .{self.selectedCount()}) catch "";
                try self.rowTxt(cnt);
                try self.rowRaw(A.reset);
            }
        } else if (self.selectedCount() == 0) {
            try self.rowRaw(A.dim);
            try self.rowTxt("(未选择)");
        } else {
            var first = true;
            for (platforms, 0..) |p, i| {
                if (!self.add_selected[i]) continue;
                if (!first) try self.rowTxt(", ");
                first = false;
                try self.rowTxt(p);
            }
        }
        try self.rowEnd(true);

        try self.inputRow("名称", self.add_name.items, self.add_step == .name);
        try self.inputRow("命令", self.add_cmd.items, self.add_step == .command);

        try self.boxBottom(true);
    }

    /// 紧凑选项切换器: "◂ 当前项 ▸ 2/4"。选项平铺放不下时的通用退化形态。
    fn optionCycler(self: *App, current: []const u8, index: usize, total: usize) !void {
        try self.rowRaw(A.dim);
        try self.rowTxt("◂ ");
        try self.rowRaw(A.reset ++ A.rev);
        try self.rowTxt(current);
        try self.rowRaw(A.reset ++ A.dim);
        try self.rowTxt(" ▸ ");
        var idx_buf: [16]u8 = undefined;
        const idx = std.fmt.bufPrint(&idx_buf, "{d}/{d}", .{ index + 1, total }) catch "";
        try self.rowTxt(idx);
        try self.rowRaw(A.reset);
    }

    fn inputRow(self: *App, label: []const u8, value: []const u8, focused: bool) !void {
        self.rowBegin();
        try self.rowTxt(if (focused) " ▸ " else "   ");
        try self.rowTxt(label);
        try self.rowPadTo(10);
        if (focused) {
            try self.rowRaw(A.yellow);
            const room = self.iw -| self.row_used -| 1;
            try self.rowTxt(tailFit(value, room));
            try self.rowRaw(A.reset ++ A.rev);
            try self.rowTxt(" ");
            try self.rowRaw(A.reset);
        } else if (value.len > 0) {
            try self.rowTxt(value);
        } else {
            try self.rowRaw(A.dim);
            try self.rowTxt("(未填写)");
        }
        try self.rowEnd(true);
    }

    fn renderStatus(self: *App) !void {
        // 保存节点模式: 状态栏变为名称输入框
        if (self.mode == .save_node) {
            try self.emit(" " ++ A.bcyan ++ "保存节点，名称: " ++ A.reset ++ A.yellow);
            try self.emit(tailFit(self.edit.items, self.w_total -| 22));
            try self.emit(A.reset ++ A.rev ++ " " ++ A.reset ++ EOL);
            return;
        }
        const color = switch (self.status_kind) {
            .info => A.dim,
            .ok => A.green,
            .err => A.bred,
        };
        try self.emit(" ");
        try self.emit(color);
        const s = self.status_buf[0..self.status_len];
        try self.emit(s[0..term.truncateBytes(s, self.w_total -| 2)]);
        try self.emit(A.reset ++ EOL);
    }

    fn renderFooter(self: *App) !void {
        const hint = switch (self.mode) {
            .normal => switch (self.panel) {
                .nodes => " ↑↓ 选择 · Enter 切换/编辑 · →/l 详情 · a/s 存节点 · d 删除 · Tab 面板 · q 退出",
                .aliases => " ↑↓ 选择 · Enter/→ 编辑详情 · a 添加别名 · d 删除 · Tab 面板 · q 退出",
                .detail => " ↑↓ 字段 · Enter 编辑 · Esc/← 返回列表 · Tab 面板 · q 退出",
            },
            .edit_field => if (self.detailTarget() != .alias and self.edit_field == protocol_field)
                " ←→ 切换协议 (http/https/socks5/socks4) · Enter 保存 · Esc 取消"
            else
                " 输入新值 · Enter 保存 · Esc 取消 · Ctrl+U 清空",
            .edit_alias_plats => " 空格 勾选平台 (可多选) · ←→ 移动 · Enter 保存 · Esc 取消",
            .add_alias => " 空格 勾选平台(可多选) · ←→ 移动 · Enter 下一步/保存 · Esc 返回",
            .confirm_delete, .confirm_del_node => " y 确认删除 · 其他任意键取消",
            .save_node => " 输入节点名 · Enter 保存 · Esc 取消 · Ctrl+U 清空",
        };
        try self.emit(A.dim);
        try self.emit(hint[0..term.truncateBytes(hint, self.w_total)]);
        // 最后一行不换行，避免整屏上滚
        try self.emit(A.reset ++ "\x1b[K");
    }

    // -- 边框与行拼装 -------------------------------------------------------

    fn borderColor(active: bool) []const u8 {
        return if (active) A.cyan else A.dim;
    }

    /// 当前行写入。capture 非空时整行捕获为独立切片，否则直接写入 frame。
    /// 面板行恰好占满面板宽度，行尾无需 \x1b[K。
    fn lbRaw(self: *App, s: []const u8) !void {
        try self.lb.appendSlice(self.allocator, s);
    }

    fn endLine(self: *App) !void {
        if (self.capture) |list| {
            try list.append(self.allocator, try self.allocator.dupe(u8, self.lb.items));
        } else {
            try self.frame.appendSlice(self.allocator, self.lb.items);
            try self.frame.appendSlice(self.allocator, "\r\n");
        }
        self.lb.clearRetainingCapacity();
    }

    fn boxTop(self: *App, title: []const u8, active: bool) !void {
        const bc = borderColor(active);
        const cut = term.truncateBytes(title, self.w_total -| 8);
        const tw = term.strWidth(title[0..cut]);

        try self.lbRaw(bc);
        try self.lbRaw("╭─ ");
        try self.lbRaw(A.reset);
        try self.lbRaw(if (active) A.bold ++ A.bcyan else A.dim);
        try self.lbRaw(title[0..cut]);
        try self.lbRaw(A.reset);
        try self.lbRaw(bc);
        try self.lbRaw(" ");
        var fill = self.w_total -| (5 + tw);
        while (fill > 0) : (fill -= 1) try self.lbRaw("─");
        try self.lbRaw("╮" ++ A.reset);
        try self.endLine();
    }

    fn boxBottom(self: *App, active: bool) !void {
        try self.lbRaw(borderColor(active));
        try self.lbRaw("╰");
        var fill = self.w_total - 2;
        while (fill > 0) : (fill -= 1) try self.lbRaw("─");
        try self.lbRaw("╯" ++ A.reset);
        try self.endLine();
    }

    fn rowBegin(self: *App) void {
        self.row.clearRetainingCapacity();
        self.row_used = 0;
    }

    /// 零宽内容 (ANSI 码)。
    fn rowRaw(self: *App, s: []const u8) !void {
        try self.row.appendSlice(self.allocator, s);
    }

    /// 可见文本，超出面板内宽自动截断 (按显示列宽，不切断多字节字符)。
    fn rowTxt(self: *App, s: []const u8) !void {
        if (self.row_used >= self.iw) return;
        const cut = term.truncateBytes(s, self.iw - self.row_used);
        try self.row.appendSlice(self.allocator, s[0..cut]);
        self.row_used += term.strWidth(s[0..cut]);
    }

    fn rowPadTo(self: *App, col: usize) !void {
        const target = @min(col, self.iw);
        while (self.row_used < target) : (self.row_used += 1) {
            try self.row.append(self.allocator, ' ');
        }
    }

    fn rowEnd(self: *App, active: bool) !void {
        const bc = borderColor(active);
        try self.lbRaw(bc);
        try self.lbRaw("│");
        try self.lbRaw(A.reset);
        try self.lb.appendSlice(self.allocator, self.row.items);
        while (self.row_used < self.iw) : (self.row_used += 1) {
            try self.lbRaw(" ");
        }
        try self.lbRaw(A.reset);
        try self.lbRaw(bc);
        try self.lbRaw("│");
        try self.lbRaw(A.reset);
        try self.endLine();
    }
};

fn freeLines(allocator: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |line| allocator.free(line);
    list.deinit(allocator);
}

/// 从末尾删除一个完整码点 (跳过 UTF-8 续字节)。
fn popCodepoint(list: *std.ArrayList(u8)) void {
    if (list.items.len == 0) return;
    var i = list.items.len - 1;
    while (i > 0 and (list.items[i] & 0xC0) == 0x80) i -= 1;
    list.shrinkRetainingCapacity(i);
}

/// 输入过长时显示尾部: 返回宽度不超过 max_width 的最长后缀。
fn tailFit(s: []const u8, max_width: usize) []const u8 {
    var start: usize = 0;
    while (start < s.len and term.strWidth(s[start..]) > max_width) {
        start += std.unicode.utf8ByteSequenceLength(s[start]) catch 1;
    }
    return s[@min(start, s.len)..];
}

test "tailFit 按显示宽度保留尾部" {
    try std.testing.expectEqualStrings("proxy", tailFit("proxy", 10));
    try std.testing.expectEqualStrings("配置", tailFit("代理配置", 4));
    try std.testing.expectEqualStrings("理配置", tailFit("代理配置", 7));
    try std.testing.expectEqualStrings("", tailFit("代理", 1));
}

test "popCodepoint 按码点删除" {
    var list: std.ArrayList(u8) = .{};
    defer list.deinit(std.testing.allocator);
    try list.appendSlice(std.testing.allocator, "a中");
    popCodepoint(&list);
    try std.testing.expectEqualStrings("a", list.items);
    popCodepoint(&list);
    try std.testing.expectEqualStrings("", list.items);
    popCodepoint(&list); // 空列表安全
}

test "renderFrame 输出行数恰好等于终端高度" {
    const allocator = std.testing.allocator;
    var app = App{
        .allocator = allocator,
        .tty = undefined, // renderFrame 不触碰终端
        .config = Config.ConfigData.init(allocator),
        .aliases = try allocator.alloc(Alias.Entry, 0),
        .groups = try allocator.alloc(Group, 0),
        .nodes = try allocator.alloc(Profile.Entry, 0),
    };
    defer app.deinit();

    // 普通模式: 每行以 \r\n 结束，末行 (快捷键栏) 不换行 → h-1 个换行
    try app.renderFrame(.{ .w = 80, .h = 24 });
    try std.testing.expectEqual(@as(usize, 23), std.mem.count(u8, app.frame.items, "\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, app.frame.items, "PROXY") != null);
    try std.testing.expect(std.mem.indexOf(u8, app.frame.items, "当前配置") != null);
    try std.testing.expect(std.mem.indexOf(u8, app.frame.items, "暂无别名") != null);

    // 弹窗模式同样必须撑满整屏且不溢出
    app.mode = .add_alias;
    try app.renderFrame(.{ .w = 60, .h = 20 });
    try std.testing.expectEqual(@as(usize, 19), std.mem.count(u8, app.frame.items, "\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, app.frame.items, "添加别名") != null);

    // 终端过小时提示而不是画烂
    app.mode = .normal;
    try app.renderFrame(.{ .w = 30, .h = 10 });
    try std.testing.expect(std.mem.indexOf(u8, app.frame.items, "终端窗口太小") != null);
}

test "宽终端主从布局撑满整屏" {
    const allocator = std.testing.allocator;
    var app = App{
        .allocator = allocator,
        .tty = undefined,
        .config = Config.ConfigData.init(allocator),
        .aliases = try allocator.alloc(Alias.Entry, 0),
        .groups = try allocator.alloc(Group, 0),
        .nodes = try allocator.alloc(Profile.Entry, 0),
    };
    defer app.deinit();

    // 头部 3 + 双栏 25 + 状态 1 = 29 个换行，末行 (快捷键栏) 不换行
    try app.renderFrame(.{ .w = 120, .h = 30 });
    try std.testing.expectEqual(@as(usize, 29), std.mem.count(u8, app.frame.items, "\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, app.frame.items, "当前配置") != null);
    try std.testing.expect(std.mem.indexOf(u8, app.frame.items, "配置 · 当前生效") != null);

    // 弹窗以悬浮层绘制 (光标定位)，不改变行数
    app.mode = .add_alias;
    try app.renderFrame(.{ .w = 120, .h = 30 });
    try std.testing.expectEqual(@as(usize, 29), std.mem.count(u8, app.frame.items, "\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, app.frame.items, "添加别名") != null);
    try std.testing.expect(std.mem.indexOf(u8, app.frame.items, ";29H") != null); // 居中定位序列
}

test "同名同命令的别名跨平台合并为一个分组" {
    const allocator = std.testing.allocator;
    var app = App{
        .allocator = allocator,
        .tty = undefined,
        .config = Config.ConfigData.init(allocator),
        .aliases = try allocator.alloc(Alias.Entry, 4),
        .groups = try allocator.alloc(Group, 0),
        .nodes = try allocator.alloc(Profile.Entry, 0),
    };
    app.aliases[0] = .{ .platform = try allocator.dupe(u8, "linux"), .name = try allocator.dupe(u8, "gs"), .command = try allocator.dupe(u8, "git status") };
    app.aliases[1] = .{ .platform = try allocator.dupe(u8, "macos"), .name = try allocator.dupe(u8, "gs"), .command = try allocator.dupe(u8, "git status") };
    app.aliases[2] = .{ .platform = try allocator.dupe(u8, "windows"), .name = try allocator.dupe(u8, "gs"), .command = try allocator.dupe(u8, "git status") };
    // 同名但命令不同 → 独立分组
    app.aliases[3] = .{ .platform = try allocator.dupe(u8, "all"), .name = try allocator.dupe(u8, "gs"), .command = try allocator.dupe(u8, "git show") };
    defer app.deinit();

    try app.rebuildGroups();
    try std.testing.expectEqual(@as(usize, 2), app.groups.len);
    try std.testing.expectEqualStrings("linux+macos+windows", app.groups[0].tags[0..app.groups[0].tags_len]);
    try std.testing.expect(app.groups[0].plats[1] and app.groups[0].plats[2] and app.groups[0].plats[3]);
    try std.testing.expect(!app.groups[0].plats[0]);
    try std.testing.expectEqualStrings("all", app.groups[1].tags[0..app.groups[1].tags_len]);
}

test {
    _ = term;
}

