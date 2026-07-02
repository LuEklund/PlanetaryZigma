const std = @import("std");
const c = @import("vulkan");
const nz = @import("shared").numz;
const Buffer = @import("Buffer.zig");
const Vma = @import("Vma.zig");
const Device = @import("device.zig").Logical;
const Font = @import("Font.zig");
const stbTruetype = @import("stb_truetype");

pub const max_ui_quads: usize = 1024;

pub const Vertex = extern struct {
    position: [2]f32,
    uv: [2]f32,
    color: [4]f32,
};

pub const Quad = struct {
    vertices: [4]Vertex,
};

const Position2D = struct {
    left: f32,
    top: f32,
};
const Size2D = struct {
    width: f32,
    heigth: f32,
};

const MouseState = struct {
    position: Position2D = .{ .left = 0, .top = 0 },
    left_click: bool = false,
    right_click: bool = false,
};

const Rect = struct {
    left: f32,
    top: f32,
    width: f32,
    heigth: f32,
};

pub const Layout = struct {
    pub const AxisAlign = enum(u8) { horizontal, verical };
    pub const Anchor = enum(u8) { start, center, end };
    pub const Position = union(enum) {
        fixed: Position2D,
        center: void,
        // percent: Position2D,
    };
    pub const Size = union(enum) {
        fixed: Size2D,
        percent: Size2D,
    };

    position: Position,
    size: Size,
    color: nz.color.Rgba(f32) = .grey,
    axis_align: AxisAlign = .horizontal,
    child_anchor: struct { x: Anchor = .start, y: Anchor = .start } = .{},
    gap: f32 = 0,
    text: ?[]const u8 = null,
    name: ?[]const u8 = null,
    children: []const Layout = &.{},
};

const Node = struct {
    id: u32,
    layout: Layout,
    name: ?[]const u8,
    parent_id: ?u32,
    rect: Rect,
    offset: f32,
    children_size: f32,
};

writter_buffer: [256]u8 = undefined,
index_buffer: Buffer,
text_buffer: [8192]u8 = undefined,
text_len: usize = 0,
quads: std.ArrayList(Quad) = .empty,
nodes: std.ArrayList(Node) = .empty,
names: std.StringArrayHashMapUnmanaged(u32) = .empty,
mouse_state: MouseState = .{},
screen_width: f32,
screen_heigth: f32,
default_font: *Font,
hot_item: ?[]const u8 = null,
active_item: ?[]const u8 = null,
fire_item: ?[]const u8 = null,
left_click_prev: bool = false,
pressed: bool = false,
released: bool = false,

pub fn init(
    gpa: std.mem.Allocator,
    vma: Vma,
    device: Device,
    screen_width: u32,
    screen_heigth: u32,
    default_font: *Font,
) !@This() {
    const ui_index_buffer: Buffer = try .init(
        device,
        vma,
        u32,
        max_ui_quads * 6,
        c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
        .{
            .usage = c.VMA_MEMORY_USAGE_AUTO,
            .flags = c.VMA_ALLOCATION_CREATE_MAPPED_BIT | c.VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT,
        },
    );
    var data: [*]u32 = @ptrCast(@alignCast(ui_index_buffer.info.pMappedData));
    for (0..max_ui_quads) |i| {
        const base: u32 = @as(u32, @intCast(i)) * 4;
        data[i * 6 ..][0..6].* = .{ base, base + 1, base + 2, base + 2, base + 3, base };
    }
    var names: std.StringArrayHashMapUnmanaged(u32) = .empty;
    try names.ensureTotalCapacity(gpa, max_ui_quads);
    return .{
        .index_buffer = ui_index_buffer,
        .quads = try .initCapacity(gpa, max_ui_quads),
        .nodes = try .initCapacity(gpa, max_ui_quads),
        .names = names,
        .screen_width = @floatFromInt(screen_width),
        .screen_heigth = @floatFromInt(screen_heigth),
        .default_font = default_font,
    };
}

pub fn deinit(self: *@This(), gpa: std.mem.Allocator, vma: Vma) void {
    self.index_buffer.deinit(vma);
    self.quads.deinit(gpa);
    self.nodes.deinit(gpa);
    self.names.deinit(gpa);
}

pub fn start(self: *@This(), mouse_state: MouseState) void {
    self.hotUpdate();
    // self.activeUpdate();
    self.text_len = 0;
    self.left_click_prev = mouse_state.left_click;
    self.nodes.clearRetainingCapacity();
    self.quads.clearRetainingCapacity();
    self.names.clearRetainingCapacity();
    self.mouse_state = mouse_state;
}

pub fn print(self: *@This(), comptime fmt: []const u8, args: anytype) []const u8 {
    const text = std.fmt.bufPrint(&self.writter_buffer, fmt, args) catch unreachable;
    return text;
}

pub fn add(self: *@This(), parent: ?[]const u8, layout: Layout) void {
    const parent_id: ?u32 = if (parent) |name| (self.names.get(name) orelse return) else null;
    self.addNode(parent_id, layout);
}

fn addNode(self: *@This(), parent_id: ?u32, layout: Layout) void {
    const handle: u32 = @intCast(self.nodes.items.len);
    self.nodes.appendAssumeCapacity(.{
        .id = handle,
        .name = layout.name,
        .layout = layout,
        .parent_id = parent_id,
        .rect = .{ .left = 0, .top = 0, .width = 0, .heigth = 0 },
        .offset = 0,
        .children_size = 0,
    });

    if (self.nodes.items[handle].layout.text) |*text| {
        @memcpy(self.text_buffer[self.text_len .. self.text_len + text.len], text.*[0..]);
        text.* = self.text_buffer[self.text_len .. self.text_len + text.len];
        self.text_len += text.len;
    }

    if (layout.name) |add_name| self.names.putAssumeCapacity(add_name, handle);
    for (layout.children) |child| self.addNode(handle, child);
}

pub fn end(self: *@This()) void {
    self.resolveLayout();
    self.pushQuads();
}

fn anchorOffset(anchor: Layout.Anchor, container: f32, children_size: f32) f32 {
    return switch (anchor) {
        .start => 0,
        .center => (container - children_size) / 2,
        .end => container - children_size,
    };
}

fn resolveLayout(self: *@This()) void {
    // pass 1: sizes (parent before child, so percent resolves against a known parent)
    for (self.nodes.items) |*node| {
        const origin: Rect = if (node.parent_id) |parent_id| self.nodes.items[parent_id].rect else self.screenRect();
        switch (node.layout.size) {
            .fixed => |size| {
                node.rect.width = size.width;
                node.rect.heigth = size.heigth;
            },
            .percent => |percent| {
                node.rect.width = percent.width * origin.width;
                node.rect.heigth = percent.heigth * origin.heigth;
            },
        }
    }

    // pass 2: accumulate flowed children's main-axis extent into each parent (bottom-up)
    var index = self.nodes.items.len;
    while (index > 0) {
        index -= 1;
        const node = self.nodes.items[index];
        const parent_id = node.parent_id orelse continue;
        if (node.layout.position == .center) continue; // out of flow, self-positioned
        const parent = &self.nodes.items[parent_id];
        parent.children_size += parent.layout.gap + switch (parent.layout.axis_align) {
            .horizontal => node.rect.width,
            .verical => node.rect.heigth,
        };
    }

    // pass 3: positions (parent before child, so its flow cursor is set before children read it)
    for (self.nodes.items) |*node| {
        const parent_node = if (node.parent_id) |parent_id| &self.nodes.items[parent_id] else null;
        const origin: Rect = if (parent_node) |parent| parent.rect else self.screenRect();

        switch (node.layout.position) {
            .center => {
                node.rect.left = origin.left + (origin.width - node.rect.width) / 2;
                node.rect.top = origin.top + (origin.heigth - node.rect.heigth) / 2;
            },
            .fixed => |position| {
                node.rect.left = origin.left + position.left;
                node.rect.top = origin.top + position.top;
                if (parent_node) |parent| {
                    const child_anchor = parent.layout.child_anchor;
                    if (parent.layout.axis_align == .horizontal) {
                        node.rect.left += parent.offset;
                        node.rect.top += anchorOffset(child_anchor.y, origin.heigth, node.rect.heigth);
                    } else {
                        node.rect.top += parent.offset;
                        node.rect.left += anchorOffset(child_anchor.x, origin.width, node.rect.width);
                    }
                    parent.offset += parent.layout.gap + switch (parent.layout.axis_align) {
                        .horizontal => node.rect.width,
                        .verical => node.rect.heigth,
                    };
                }
            },
        }

        // start this node's own flow cursor at its main-axis alignment
        const extent = if (node.children_size > 0) node.children_size - node.layout.gap else 0;
        node.offset = switch (node.layout.axis_align) {
            .horizontal => anchorOffset(node.layout.child_anchor.x, node.rect.width, extent),
            .verical => anchorOffset(node.layout.child_anchor.y, node.rect.heigth, extent),
        };
    }
}

fn screenRect(self: *const @This()) Rect {
    return .{ .left = 0, .top = 0, .width = self.screen_width, .heigth = self.screen_heigth };
}

fn pushQuads(self: *@This()) void {
    for (self.nodes.items) |node| {
        const rect = node.rect;
        const colors: [4]f32 = node.layout.color.toVec();
        //left_top, right_top, right_bottom, left_bottom
        self.quads.appendAssumeCapacity(.{ .vertices = .{
            .{ .position = .{ rect.left, rect.top }, .color = colors, .uv = .{ -1, -1 } },
            .{ .position = .{ rect.left + rect.width, rect.top }, .color = colors, .uv = .{ -1, -1 } },
            .{ .position = .{ rect.left + rect.width, rect.top + rect.heigth }, .color = colors, .uv = .{ -1, -1 } },
            .{ .position = .{ rect.left, rect.top + rect.heigth }, .color = colors, .uv = .{ -1, -1 } },
        } });
        if (node.layout.text) |text| {
            const color: nz.color.Rgba(f32) = .new(1, 0, 0, 1);
            const colo = color.toVec();
            const font = self.default_font;
            var pen: struct {
                x: f32,
                y: f32,
            } = .{
                .x = node.rect.left,
                .y = node.rect.top + font.size,
            };
            for (text) |char| {
                var index: c_int = @as(c_int, char) - 32;
                if (index > 96 or index < 0) index = 96;
                var quad: stbTruetype.stbtt_aligned_quad = undefined;
                stbTruetype.stbtt_packedchar.GetPackedQuad(&font.chars, 512, 512, index, &pen.x, &pen.y, &quad, 0);

                self.quads.appendAssumeCapacity(.{ .vertices = .{
                    .{ .position = .{ quad.x0, quad.y0 }, .color = colo, .uv = .{ quad.s0, quad.t0 } },
                    .{ .position = .{ quad.x1, quad.y0 }, .color = colo, .uv = .{ quad.s1, quad.t0 } },
                    .{ .position = .{ quad.x1, quad.y1 }, .color = colo, .uv = .{ quad.s1, quad.t1 } },
                    .{ .position = .{ quad.x0, quad.y1 }, .color = colo, .uv = .{ quad.s0, quad.t1 } },
                } });
            }
        }
    }
}

// pub fn clicked(self: *@This(), id: u32) ?*Layout {
//     if (id >= self.nodes.items.len) return null;
//     const node = self.nodes.items[id];
// }

pub fn isHot(self: *@This(), name: []const u8) bool {
    return eqlName(name, self.hot_item);
}

pub fn isActive(self: *@This(), name: []const u8) bool {
    return (eqlName(name, self.hot_item) and self.mouse_state.left_click);
}

fn hotUpdate(self: *@This()) void {
    self.hot_item = null;
    var i = self.nodes.items.len;
    while (i > 0) {
        i -= 1;
        const node = self.nodes.items[i];
        const name = node.name orelse continue;
        if (!(self.mouse_state.position.left < node.rect.left or
            self.mouse_state.position.top < node.rect.top or
            self.mouse_state.position.left >= node.rect.left + node.rect.width or
            self.mouse_state.position.top >= node.rect.top + node.rect.heigth))
        {
            self.hot_item = name;
            break;
        }
    }
}

// fn activeUpdate(self: *@This()) void {
//     if (self.hot_item)
//     if (self.left_click_prev) return;
// }

fn eqlName(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null)
        return false;
    return std.mem.eql(u8, a.?, b.?);
}
