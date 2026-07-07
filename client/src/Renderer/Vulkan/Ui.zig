const std = @import("std");
const c = @import("vulkan");
const nz = @import("shared").numz;
const Buffer = @import("Buffer.zig");
const Vma = @import("Vma.zig");
const Device = @import("device.zig").Logical;
const Font = @import("Font.zig");

pub const max_ui_quads: usize = 1024;

pub const Texture = enum {
    blank,
    font_atlas,
    damage_item,
    crosshair,
    oxygen_tank,
    energy_drink,

    pub fn toInt(self: @This()) u32 {
        return @intFromEnum(self);
    }

    pub fn path(self: @This()) ?[:0]const u8 {
        return switch (self) {
            .blank, .font_atlas => null,
            .damage_item => "assets/textures/damage.png",
            .oxygen_tank => "assets/textures/oxygen_tank.png",
            .crosshair => "assets/textures/crosshair.png",
            .energy_drink => "assets/textures/energy_drink.png",
        };
    }
};

pub const Vertex = extern struct {
    position: [2]f32,
    uv: [2]f32,
    color: [4]f32,
    texture_index: u32 = 0,
    is_sdf: u32 = 0,
    _: [2]u32 = .{ 0, 0 },
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
    pub const Size = union(enum) {
        fixed: Size2D,
        percent: Size2D,
    };
    pub const Text = struct {
        data: []const u8,
        size: f32 = 32,
        color: nz.color.Rgba(f32) = .new(1, 1, 1, 1),
    };

    offset: Position2D = .{ .left = 0, .top = 0 },
    size: Size,
    color: nz.color.Rgba(f32) = .new(0, 0, 0, 0),
    axis_align: AxisAlign = .horizontal,
    child_anchor: struct { x: Anchor = .start, y: Anchor = .start } = .{},
    texture: Texture = .blank,
    gap: f32 = 0,
    text: ?Text = null,
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
        const data = text.data;
        @memcpy(self.text_buffer[self.text_len .. self.text_len + data.len], data);
        text.data = self.text_buffer[self.text_len .. self.text_len + data.len];
        self.text_len += data.len;
    }

    if (layout.name) |add_name| self.names.putAssumeCapacity(add_name, handle);
    for (layout.children) |child| self.addNode(handle, child);
}

pub fn end(self: *@This()) void {
    self.resolveLayout();
    self.pushQuads();
}

const TextMetrics = struct { width: f32, top: f32, bottom: f32 };

fn measureText(glyphs: *const [96]Font.Glyph, text: []const u8, scale: f32) TextMetrics {
    var metrics: TextMetrics = .{ .width = 0, .top = 0, .bottom = 0 };
    for (text) |char| {
        const index: usize = @intCast(std.math.clamp(@as(c_int, char) - 32, 0, 95));
        const glyph = glyphs[index];
        metrics.width += glyph.xadvance * scale;
        metrics.top = @min(metrics.top, glyph.yoff * scale); // yoff is negative (above baseline)
        metrics.bottom = @max(metrics.bottom, (glyph.yoff + glyph.heigth) * scale);
    }
    return metrics;
}

pub fn textSize(self: *const @This(), text: []const u8, size: f32) Size2D {
    const scale = size / self.default_font.size;
    const metrics = measureText(&self.default_font.glyphs, text, scale);
    return .{ .width = metrics.width, .heigth = metrics.bottom - metrics.top };
}

fn startOffset(anchor: Layout.Anchor, available: f32, request: f32) f32 {
    return switch (anchor) {
        .start => 0,
        .center => (available - request) / 2,
        .end => available - request,
    };
}

fn resolveLayout(self: *@This()) void {
    // pass 1: sizes (parent before child, so percent resolves against a known parent)
    for (self.nodes.items) |*node| {
        const origin: Rect = if (node.parent_id) |parent_id| self.nodes.items[parent_id].rect else self.screenRect();
        const layout: *Layout = &node.layout;

        switch (layout.size) {
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

    // pass 2: each child adds its main-axis size (+gap) into its parent's children_size (bottom-up)
    var index = self.nodes.items.len;
    while (index > 0) {
        index -= 1;
        const child = self.nodes.items[index];
        const parent_id = child.parent_id orelse continue;
        const parent = &self.nodes.items[parent_id];
        parent.children_size += parent.layout.gap + switch (parent.layout.axis_align) {
            .horizontal => child.rect.width,
            .verical => child.rect.heigth,
        };
    }

    // pass 3: positions (parent before child, so parent.offset is set before its children read it)
    for (self.nodes.items) |*node| {
        const parent_node = if (node.parent_id) |parent_id| &self.nodes.items[parent_id] else null;
        const origin: Rect = if (parent_node) |parent| parent.rect else self.screenRect();

        node.rect.left = origin.left + node.layout.offset.left;
        node.rect.top = origin.top + node.layout.offset.top;
        if (parent_node) |parent| {
            const child_anchor = parent.layout.child_anchor;
            if (parent.layout.axis_align == .horizontal) {
                node.rect.left += parent.offset;
                node.rect.top += startOffset(child_anchor.y, origin.heigth, node.rect.heigth);
            } else {
                node.rect.top += parent.offset;
                node.rect.left += startOffset(child_anchor.x, origin.width, node.rect.width);
            }
            parent.offset += parent.layout.gap + switch (parent.layout.axis_align) {
                .horizontal => node.rect.width,
                .verical => node.rect.heigth,
            };
        }

        // initialize this node's offset (where its first child starts) from its main-axis anchor
        const extent = if (node.children_size > 0) node.children_size - node.layout.gap else 0;
        node.offset = switch (node.layout.axis_align) {
            .horizontal => startOffset(node.layout.child_anchor.x, node.rect.width, extent),
            .verical => startOffset(node.layout.child_anchor.y, node.rect.heigth, extent),
        };
    }
}

fn screenRect(self: *const @This()) Rect {
    return .{ .left = 0, .top = 0, .width = self.screen_width, .heigth = self.screen_heigth };
}

fn pushQuads(self: *@This()) void {
    for (self.nodes.items) |node| {
        const rect = node.rect;
        if (node.layout.color.a != 0) {
            const colors: [4]f32 = node.layout.color.toVec();
            //left_top, right_top, right_bottom, left_bottom
            self.quads.appendAssumeCapacity(.{ .vertices = .{
                .{ .position = .{ rect.left, rect.top }, .color = colors, .uv = .{ 0, 0 }, .is_sdf = 0, .texture_index = node.layout.texture.toInt() },
                .{ .position = .{ rect.left + rect.width, rect.top }, .color = colors, .uv = .{ 1, 0 }, .is_sdf = 0, .texture_index = node.layout.texture.toInt() },
                .{ .position = .{ rect.left + rect.width, rect.top + rect.heigth }, .color = colors, .uv = .{ 1, 1 }, .is_sdf = 0, .texture_index = node.layout.texture.toInt() },
                .{ .position = .{ rect.left, rect.top + rect.heigth }, .color = colors, .uv = .{ 0, 1 }, .is_sdf = 0, .texture_index = node.layout.texture.toInt() },
            } });
        }
        if (node.layout.text) |text| {
            const color = text.color.toVec();
            const font = self.default_font;
            const anchor = node.layout.child_anchor;
            const scale = text.size / font.size;
            const metrics = measureText(&font.glyphs, text.data, scale);
            var pen: struct {
                x: f32,
                y: f32,
            } = .{
                .x = node.rect.left + startOffset(anchor.x, node.rect.width, metrics.width),
                .y = node.rect.top + startOffset(anchor.y, node.rect.heigth, metrics.bottom - metrics.top) - metrics.top,
            };
            for (text.data) |char| {
                const index: usize = @intCast(std.math.clamp(@as(c_int, char) - 32, 0, 95));
                const glyph = font.glyphs[index];
                const x0 = pen.x + glyph.xoff * scale;
                const y0 = pen.y + glyph.yoff * scale;
                const x1 = x0 + glyph.width * scale;
                const y1 = y0 + glyph.heigth * scale;
                self.quads.appendAssumeCapacity(.{ .vertices = .{
                    .{ .position = .{ x0, y0 }, .color = color, .uv = .{ glyph.u0, glyph.v0 }, .is_sdf = 1, .texture_index = Texture.font_atlas.toInt() },
                    .{ .position = .{ x1, y0 }, .color = color, .uv = .{ glyph.u1, glyph.v0 }, .is_sdf = 1, .texture_index = Texture.font_atlas.toInt() },
                    .{ .position = .{ x1, y1 }, .color = color, .uv = .{ glyph.u1, glyph.v1 }, .is_sdf = 1, .texture_index = Texture.font_atlas.toInt() },
                    .{ .position = .{ x0, y1 }, .color = color, .uv = .{ glyph.u0, glyph.v1 }, .is_sdf = 1, .texture_index = Texture.font_atlas.toInt() },
                } });
                pen.x += glyph.xadvance * scale;
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
