const Ui = @This();

const std = @import("std");
const nz = @import("numz");
const Font = @import("shared").Font;

const contract = @import("renderer_contract");
const DrawList = contract.DrawList;

pub const max_ui_quads = DrawList.max_ui_quads;
pub const Vertex = DrawList.UiVertex;
pub const Quad = DrawList.UiQuad;

writer_buffer_out: [8192]u8 = undefined,
writer_len: usize = 0,
text_buffer: [8192]u8 = undefined,
text_len: usize = 0,
quads: std.ArrayList(Quad) = .empty,
nodes: std.ArrayList(Node) = .empty,
names: std.AutoArrayHashMapUnmanaged(u64, u32) = .empty,
animations: std.AutoArrayHashMapUnmanaged(u64, Animation) = .empty,
mouse_state: MouseState = .{},
screen_width: f32,
screen_height: f32,
default_font: *const Font,

hover_item: ?u64 = null,
active_item: ?u64 = null,
last_hover_item: ?u64 = null,
last_active_item: ?u64 = null,

play_sound: enum { none, hover, clicked } = .none,

left_click_prev: bool = false,
pressed: bool = false,
released: bool = false,
delta_time: f32 = 0,
frame_index: u64 = 0,

pub fn key(name: []const u8) u64 {
    return std.hash.Wyhash.hash(0, name);
}

const Animation = struct {
    value: f32,
    last_frame: u64,
};

const Node = struct {
    id: u32,
    layout: Layout,
    name: ?u64,
    parent_id: ?u32,
    rect: Rect,
    offset: f32,
    children_size: f32,
};

const Position2D = struct {
    left: f32,
    top: f32,
};

pub const Size2D = struct {
    width: f32,
    height: f32,
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
    height: f32,
};

pub const Layout = struct {
    pub const AxisAlign = enum(u8) { horizontal, vertical };
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
    texture: contract.TextureHandle = .blank,
    gap: f32 = 0,
    padding: f32 = 0,
    floating: bool = false,
    text: ?Text = null,
    name: ?[]const u8 = null,
    children: []const Layout = &.{},
};

pub fn init(
    gpa: std.mem.Allocator,
    screen_width: u32,
    screen_height: u32,
) !Ui {
    var names: std.AutoArrayHashMapUnmanaged(u64, u32) = .empty;
    try names.ensureTotalCapacity(gpa, max_ui_quads);
    var animations: std.AutoArrayHashMapUnmanaged(u64, Animation) = .empty;
    try animations.ensureTotalCapacity(gpa, max_ui_quads);
    return .{
        .quads = try .initCapacity(gpa, max_ui_quads),
        .nodes = try .initCapacity(gpa, max_ui_quads),
        .names = names,
        .animations = animations,
        .screen_width = @floatFromInt(screen_width),
        .screen_height = @floatFromInt(screen_height),
        .default_font = &Font.empty,
    };
}

pub fn deinit(self: *Ui, gpa: std.mem.Allocator) void {
    self.quads.deinit(gpa);
    self.nodes.deinit(gpa);
    self.names.deinit(gpa);
    self.animations.deinit(gpa);
}

pub fn start(self: *Ui, mouse_state: MouseState, font: *const Font, delta_time: f32) void {
    self.default_font = font;
    const left_click_prev = self.mouse_state.left_click;
    self.last_active_item = self.active_item;
    self.last_hover_item = self.hover_item;
    self.play_sound = .none;
    self.mouse_state = mouse_state;
    self.delta_time = delta_time;
    self.frame_index += 1;
    self.hoverUpdate();
    if (mouse_state.left_click and !left_click_prev) self.active_item = self.hover_item;
    if (!mouse_state.left_click) self.active_item = null;
    self.text_len = 0;
    self.writer_len = 0;
    self.left_click_prev = left_click_prev;
    self.pressed = mouse_state.left_click and !left_click_prev;
    self.released = !mouse_state.left_click and left_click_prev;
    self.nodes.clearRetainingCapacity();
    self.quads.clearRetainingCapacity();
    self.names.clearRetainingCapacity();
}

pub fn end(self: *Ui) void {
    self.resolveLayout();
    self.pushQuads();

    var index: usize = 0;
    while (index < self.animations.count()) {
        if (self.animations.values()[index].last_frame == self.frame_index) {
            index += 1;
        } else {
            self.animations.swapRemoveAt(index);
        }
    }
}

pub fn animate(self: *Ui, name: []const u8, target: f32, seconds: f32) f32 {
    const entry = self.animations.getOrPutAssumeCapacity(key(name));
    if (!entry.found_existing) entry.value_ptr.* = .{ .value = 0, .last_frame = self.frame_index };
    const animation: *Animation = entry.value_ptr;
    animation.last_frame = self.frame_index;
    animation.value += (target - animation.value) * (1 - @exp(-self.delta_time / @max(seconds, 0.0001)));
    if (@abs(target - animation.value) < 0.001) animation.value = target;
    return animation.value;
}

pub fn print(self: *Ui, comptime fmt: []const u8, args: anytype) []const u8 {
    const text = std.fmt.bufPrint(self.writer_buffer_out[self.writer_len..], fmt, args) catch unreachable;
    self.writer_len += text.len;
    return text;
}

pub fn add(self: *Ui, parent: ?[]const u8, layout: Layout) void {
    const parent_id: ?u32 = if (parent) |name| (self.names.get(key(name)) orelse return) else null;
    self.addNode(parent_id, layout);
}

fn addNode(self: *Ui, parent_id: ?u32, layout: Layout) void {
    const handle: u32 = @intCast(self.nodes.items.len);
    self.nodes.appendAssumeCapacity(.{
        .id = handle,
        .name = if (layout.name) |node_name| key(node_name) else null,
        .layout = layout,
        .parent_id = parent_id,
        .rect = .{ .left = 0, .top = 0, .width = 0, .height = 0 },
        .offset = 0,
        .children_size = 0,
    });

    if (self.nodes.items[handle].layout.text) |*text| {
        const data = text.data;
        @memcpy(self.text_buffer[self.text_len .. self.text_len + data.len], data);
        text.data = self.text_buffer[self.text_len .. self.text_len + data.len];
        self.text_len += data.len;
    }

    if (layout.name) |add_name| self.names.putAssumeCapacity(key(add_name), handle);
    for (layout.children) |child| self.addNode(handle, child);
}

const TextMetrics = struct { width: f32, top: f32, bottom: f32 };

fn measureText(glyphs: *const [96]Font.Glyph, text: []const u8, scale: f32) TextMetrics {
    var metrics: TextMetrics = .{ .width = 0, .top = 0, .bottom = 0 };
    for (text) |char| {
        const index: usize = @intCast(std.math.clamp(@as(i32, char) - 32, 0, 95));
        const glyph = glyphs[index];
        metrics.width += glyph.xadvance * scale;
        metrics.top = @min(metrics.top, glyph.yoff * scale); // yoff is negative (above baseline)
        metrics.bottom = @max(metrics.bottom, (glyph.yoff + glyph.height) * scale);
    }
    return metrics;
}

pub fn worldToScreen(self: *const Ui, view_proj: nz.Mat4x4(f32), world_position: nz.Vec3(f32)) ?[2]f32 {
    if (self.screen_width <= 0 or self.screen_height <= 0) return null;

    const clip = view_proj.mulVec4(.{ world_position[0], world_position[1], world_position[2], 1 });
    if (clip[3] <= 0.001) return null;

    const ndc = clip / @as(nz.Vec4(f32), @splat(clip[3]));
    if (ndc[0] < -1 or ndc[0] > 1 or ndc[1] < -1 or ndc[1] > 1 or ndc[2] < 0 or ndc[2] > 1) return null;
    return .{
        (ndc[0] * 0.5 + 0.5) * self.screen_width,
        (ndc[1] * 0.5 + 0.5) * self.screen_height,
    };
}

pub fn textSize(self: *const Ui, text: []const u8, size: f32) Size2D {
    const scale = size / self.default_font.size;
    const metrics = measureText(&self.default_font.glyphs, text, scale);
    return .{ .width = metrics.width, .height = metrics.bottom - metrics.top };
}

fn startOffset(anchor: Layout.Anchor, available: f32, request: f32, padding: f32) f32 {
    return switch (anchor) {
        .start => padding,
        .center => (available - request) / 2,
        .end => available - padding - request,
    };
}

fn resolveLayout(self: *Ui) void {
    // pass 1: sizes (parent before child, so percent resolves against a known parent)
    for (self.nodes.items) |*node| {
        const origin: Rect = if (node.parent_id) |parent_id| self.nodes.items[parent_id].rect else self.screenRect();
        const layout: *Layout = &node.layout;

        switch (layout.size) {
            .fixed => |size| {
                node.rect.width = size.width;
                node.rect.height = size.height;
            },
            .percent => |percent| {
                node.rect.width = percent.width * origin.width;
                node.rect.height = percent.height * origin.height;
            },
        }
    }
    //TODO: grow parent to children
    //TODO: fit children to parent

    // pass 2: each child adds its main-axis size (+gap) into its parent's children_size (bottom-up)
    var index = self.nodes.items.len;
    while (index > 0) {
        index -= 1;
        const child = self.nodes.items[index];
        if (child.layout.floating) continue;
        const parent_id = child.parent_id orelse continue;
        const parent = &self.nodes.items[parent_id];
        parent.children_size += parent.layout.gap + switch (parent.layout.axis_align) {
            .horizontal => child.rect.width,
            .vertical => child.rect.height,
        };
    }

    // pass 3: positions (parent before child, so parent.offset is set before its children read it)
    for (self.nodes.items) |*node| {
        const parent_node = if (node.parent_id) |parent_id| &self.nodes.items[parent_id] else null;
        const origin: Rect = if (parent_node) |parent| parent.rect else self.screenRect();

        node.rect.left = origin.left + node.layout.offset.left;
        node.rect.top = origin.top + node.layout.offset.top;
        if (parent_node) |parent| if (!node.layout.floating) {
            const child_anchor = parent.layout.child_anchor;
            if (parent.layout.axis_align == .horizontal) {
                node.rect.left += parent.offset;
                node.rect.top += startOffset(child_anchor.y, origin.height, node.rect.height, parent.layout.padding);
            } else {
                node.rect.top += parent.offset;
                node.rect.left += startOffset(child_anchor.x, origin.width, node.rect.width, parent.layout.padding);
            }

            parent.offset += parent.layout.gap + switch (parent.layout.axis_align) {
                .horizontal => node.rect.width,
                .vertical => node.rect.height,
            };
        };

        // initialize this node's offset (where its first child starts) from its main-axis anchor
        const extent = if (node.children_size > 0) node.children_size - node.layout.gap else 0;
        node.offset = switch (node.layout.axis_align) {
            .horizontal => startOffset(node.layout.child_anchor.x, node.rect.width, extent, node.layout.padding),
            .vertical => startOffset(node.layout.child_anchor.y, node.rect.height, extent, node.layout.padding),
        };
    }
}

fn screenRect(self: *const Ui) Rect {
    return .{ .left = 0, .top = 0, .width = self.screen_width, .height = self.screen_height };
}

fn pushQuads(self: *Ui) void {
    for (self.nodes.items) |node| {
        const rect = node.rect;
        if (node.layout.color.a != 0) {
            const colors: [4]f32 = node.layout.color.toVec();
            self.quads.appendAssumeCapacity(.{ .vertices = .{
                .{ .position = .{ rect.left, rect.top }, .color = colors, .uv = .{ 0, 0 }, .is_sdf = 0, .texture_index = @intFromEnum(node.layout.texture) },
                .{ .position = .{ rect.left + rect.width, rect.top }, .color = colors, .uv = .{ 1, 0 }, .is_sdf = 0, .texture_index = @intFromEnum(node.layout.texture) },
                .{ .position = .{ rect.left + rect.width, rect.top + rect.height }, .color = colors, .uv = .{ 1, 1 }, .is_sdf = 0, .texture_index = @intFromEnum(node.layout.texture) },
                .{ .position = .{ rect.left, rect.top + rect.height }, .color = colors, .uv = .{ 0, 1 }, .is_sdf = 0, .texture_index = @intFromEnum(node.layout.texture) },
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
                .x = node.rect.left + startOffset(anchor.x, node.rect.width, metrics.width, node.layout.padding),
                .y = node.rect.top + startOffset(anchor.y, node.rect.height, metrics.bottom - metrics.top, node.layout.padding) - metrics.top,
            };
            for (text.data) |char| {
                const index: usize = @intCast(std.math.clamp(@as(i32, char) - 32, 0, 95));
                const glyph = font.glyphs[index];
                const x0 = pen.x + glyph.xoff * scale;
                const y0 = pen.y + glyph.yoff * scale;
                const x1 = x0 + glyph.width * scale;
                const y1 = y0 + glyph.height * scale;
                self.quads.appendAssumeCapacity(.{ .vertices = .{
                    .{ .position = .{ x0, y0 }, .color = color, .uv = .{ glyph.u0, glyph.v0 }, .is_sdf = 1, .texture_index = font.atlas_texture_index },
                    .{ .position = .{ x1, y0 }, .color = color, .uv = .{ glyph.u1, glyph.v0 }, .is_sdf = 1, .texture_index = font.atlas_texture_index },
                    .{ .position = .{ x1, y1 }, .color = color, .uv = .{ glyph.u1, glyph.v1 }, .is_sdf = 1, .texture_index = font.atlas_texture_index },
                    .{ .position = .{ x0, y1 }, .color = color, .uv = .{ glyph.u0, glyph.v1 }, .is_sdf = 1, .texture_index = font.atlas_texture_index },
                } });
                pen.x += glyph.xadvance * scale;
            }
        }
    }
}

pub fn addText(self: *Ui, parent: ?[]const u8, text: []const u8, size: f32, left: f32, top: f32) void {
    self.add(parent, .{
        .size = .{ .fixed = self.textSize(text, size) },
        .offset = .{ .left = left, .top = top },
        .text = .{ .data = text, .size = size, .color = .new(0.94, 0.96, 0.9, 1) },
    });
}

pub fn addButton(self: *Ui, parent: ?[]const u8, name: []const u8, text: []const u8, left: f32, top: f32, width: f32, height: f32) void {
    const hovered = self.isHovered(name);
    self.add(parent, .{
        .name = name,
        .size = .{ .fixed = .{ .width = width, .height = height } },
        .offset = .{ .left = left, .top = top },
        .color = if (hovered) .new(0.88, 0.55, 0.08, 0.96) else .new(0.06, 0.065, 0.055, 0.96),
        .child_anchor = .{ .x = .center, .y = .center },
        .text = .{
            .data = text,
            .size = std.math.clamp(height * 0.52, @as(f32, 21), @as(f32, 27)),
            .color = if (hovered) .new(0.02, 0.02, 0.015, 1) else .new(0.94, 0.96, 0.9, 1),
        },
    });
}

pub fn addToggle(self: *Ui, parent: ?[]const u8, name: []const u8, label: []const u8, value: bool, left: f32, top: f32, width: f32, height: f32) bool {
    const box_side = height - 10;
    const hovered = self.isHovered(name);
    self.add(parent, .{
        .size = .{ .fixed = .{ .width = width, .height = height } },
        .offset = .{ .left = left, .top = top },
        .color = .new(0.035, 0.04, 0.038, 0.82),
        .child_anchor = .{ .x = .start, .y = .center },
        .children = &.{
            .{
                .size = .{ .fixed = .{ .width = width - box_side - 24, .height = height } },
                .offset = .{ .left = 14, .top = 0 },
                .child_anchor = .{ .x = .start, .y = .center },
                .text = .{ .data = label, .size = 22, .color = .new(0.9, 0.93, 0.86, 1) },
            },
            .{
                .name = name,
                .size = .{ .fixed = .{ .width = box_side, .height = box_side } },
                .color = if (hovered) .new(0.88, 0.55, 0.08, 0.96) else .new(0.06, 0.065, 0.055, 0.96),
                .child_anchor = .{ .x = .center, .y = .center },
                .text = if (value) .{
                    .data = "x",
                    .size = box_side * 0.7,
                    .color = if (hovered) .new(0.02, 0.02, 0.015, 1) else .new(0.94, 0.96, 0.9, 1),
                } else null,
            },
        },
    });
    return self.isClicked(name);
}

pub fn addSlider(self: *Ui, parent: ?[]const u8, name: []const u8, label: []const u8, value: f32, min: f32, max: f32, left: f32, top: f32, width: f32, height: f32, value_text: []const u8) ?f32 {
    const value_width = std.math.clamp(width * 0.2, @as(f32, 82), @as(f32, 130));
    const label_width = std.math.clamp(width * 0.28, @as(f32, 160), @as(f32, 230));
    const track_left = left + label_width + 16;
    const track_width = width - label_width - value_width - 34;
    const track_height = @max(@as(f32, 8), height * 0.24);
    const track_top = top + (height - track_height) * 0.5;
    const normalized = std.math.clamp((value - min) / (max - min), @as(f32, 0), @as(f32, 1));

    self.add(parent, .{
        .size = .{ .fixed = .{ .width = width, .height = height } },
        .offset = .{ .left = left, .top = top },
        .color = .new(0.035, 0.04, 0.038, 0.82),
    });
    self.add(parent, .{
        .size = .{ .fixed = .{ .width = label_width, .height = height } },
        .offset = .{ .left = left + 14, .top = top },
        .child_anchor = .{ .x = .start, .y = .center },
        .text = .{ .data = label, .size = 20, .color = .new(0.9, 0.93, 0.86, 1) },
    });
    self.add(parent, .{
        .size = .{ .fixed = .{ .width = track_width, .height = track_height } },
        .offset = .{ .left = track_left, .top = track_top },
        .color = .new(0.09, 0.1, 0.095, 1),
    });
    self.add(parent, .{
        .size = .{ .fixed = .{ .width = track_width * normalized, .height = track_height } },
        .offset = .{ .left = track_left, .top = track_top },
        .color = .new(0.88, 0.55, 0.08, 0.96),
    });
    self.add(parent, .{
        .size = .{ .fixed = .{ .width = 10, .height = height - 10 } },
        .offset = .{ .left = track_left + track_width * normalized - 5, .top = top + 5 },
        .color = .new(0.94, 0.96, 0.9, 1),
    });
    self.add(parent, .{
        .size = .{ .fixed = .{ .width = value_width, .height = height - 8 } },
        .offset = .{ .left = left + width - value_width, .top = top + 4 },
        .color = .new(0.06, 0.065, 0.055, 0.96),
        .child_anchor = .{ .x = .center, .y = .center },
        .text = .{ .data = value_text, .size = 20, .color = .new(0.94, 0.96, 0.9, 1) },
    });
    self.add(parent, .{
        .name = name,
        .size = .{ .fixed = .{ .width = track_width, .height = height } },
        .offset = .{ .left = track_left, .top = top },
        .color = .new(0, 0, 0, 0),
    });

    if (!self.isDragging(name)) return null;
    const mouse_x = std.math.clamp(self.mouse_state.position.left, track_left, track_left + track_width);
    return min + ((mouse_x - track_left) / track_width) * (max - min);
}

pub fn isHovered(self: *Ui, name: []const u8) bool {
    if (self.hover_item == key(name)) {
        if (self.last_hover_item != self.hover_item) {
            std.log.debug("hover: {any}", .{self.hover_item});
            self.play_sound = .hover;
        }

        return true;
    }
    return false;
}

pub fn isClicked(self: *Ui, name: []const u8) bool {
    if (self.hover_item == key(name) and self.pressed) {
        if (self.active_item != self.last_active_item) {
            std.log.debug("clciked: {any}", .{self.active_item});

            self.play_sound = .clicked;
        }
        return true;
    }
    return false;
}

pub fn isDragging(self: *Ui, name: []const u8) bool {
    return (self.active_item == key(name) and self.mouse_state.left_click);
}

fn hoverUpdate(self: *Ui) void {
    self.hover_item = null;
    var i = self.nodes.items.len;
    while (i > 0) {
        i -= 1;
        const node = self.nodes.items[i];
        const name = node.name orelse continue;
        if (!(self.mouse_state.position.left < node.rect.left or
            self.mouse_state.position.top < node.rect.top or
            self.mouse_state.position.left >= node.rect.left + node.rect.width or
            self.mouse_state.position.top >= node.rect.top + node.rect.height))
        {
            self.hover_item = name;
            break;
        }
    }
}
