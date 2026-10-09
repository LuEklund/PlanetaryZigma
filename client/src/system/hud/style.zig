const std = @import("std");
const dvui = @import("dvui");
const shared = @import("shared");
const nz = shared.numz;
const contract = @import("renderer_contract");
const Backend = @import("dvui_backend");

pub const text: dvui.Color = .{ .r = 240, .g = 245, .b = 230 };
pub const text_dim: dvui.Color = .{ .r = 173, .g = 184, .b = 168 };
pub const text_dark: dvui.Color = .{ .r = 5, .g = 5, .b = 4 };
pub const accent: dvui.Color = .{ .r = 224, .g = 140, .b = 20 };
pub const panel: dvui.Color = .{ .r = 5, .g = 6, .b = 6, .a = 235 };
pub const control: dvui.Color = .{ .r = 15, .g = 17, .b = 14, .a = 245 };
pub const disabled: dvui.Color = .{ .r = 11, .g = 12, .b = 11, .a = 255 };
pub const scrim: dvui.Color = .{ .r = 0, .g = 0, .b = 0, .a = 133 };
pub const good: dvui.Color = .{ .r = 100, .g = 240, .b = 100 };

pub fn font(size: f32) dvui.Font {
    return dvui.Font.theme(.body).withSize(size);
}

pub fn rgba(color: [4]f32) dvui.Color {
    return .{
        .r = @intFromFloat(std.math.clamp(color[0], 0, 1) * 255),
        .g = @intFromFloat(std.math.clamp(color[1], 0, 1) * 255),
        .b = @intFromFloat(std.math.clamp(color[2], 0, 1) * 255),
        .a = @intFromFloat(std.math.clamp(color[3], 0, 1) * 255),
    };
}

pub fn screen() dvui.Rect {
    const natural = dvui.windowRect();
    return .{ .x = natural.x, .y = natural.y, .w = natural.w, .h = natural.h };
}

pub fn button(src: std.builtin.SourceLocation, label: []const u8, id_extra: usize, size: dvui.Size, selected: bool, enabled: bool) bool {
    const fill = if (!enabled) disabled else if (selected) accent else control;
    const fg = if (!enabled) text_dim else if (selected) text_dark else text;
    const clicked = dvui.button(src, label, .{ .draw_focus = false }, .{
        .id_extra = id_extra,
        .min_size_content = size,
        .expand = .horizontal,
        .font = font(@min(22, @max(16, size.h * 0.48))),
        .color_fill = .fromColor(fill),
        .color_fill_hover = .fromColor(if (enabled) accent else fill),
        .color_fill_press = .fromColor(if (enabled) accent.lerp(.white, 0.2) else fill),
        .color_text = .fromColor(fg),
        .color_text_hover = .fromColor(if (enabled) text_dark else fg),
        .color_text_press = .fromColor(if (enabled) text_dark else fg),
        .corners = .all(0),
        .margin = .{ .y = 4, .h = 4 },
    });
    return clicked and enabled;
}

pub fn fillScreen(color: dvui.Color) void {
    dvui.windowRectPixels().fill(.all(0), .{ .color = .fromColor(color) });
}

pub fn fillRect(rect: dvui.Rect, color: dvui.Color) void {
    const scale = dvui.windowNaturalScale();
    const physical: dvui.Rect.Physical = .{ .x = rect.x * scale, .y = rect.y * scale, .w = rect.w * scale, .h = rect.h * scale };
    physical.fill(.all(0), .{ .color = .fromColor(color) });
}

pub fn centeredPanel(src: std.builtin.SourceLocation, width: f32, height: f32) *dvui.BoxWidget {
    const area = screen();
    return dvui.box(src, .{ .dir = .vertical }, .{
        .rect = .{ .x = (area.w - width) / 2, .y = (area.h - height) / 2, .w = width, .h = height },
        .background = true,
        .color_fill = .fromColor(panel),
        .padding = .all(18),
        .corners = .all(0),
    });
}

pub fn title(src: std.builtin.SourceLocation, label: []const u8) void {
    dvui.labelNoFmt(src, label, .{}, .{ .font = font(34), .color_text = .fromColor(text), .gravity_x = 0.5, .padding = .{ .y = 4, .h = 12 } });
}

pub fn worldToScreen(view_proj: nz.Mat4x4(f32), world_position: nz.Vec3(f32)) ?[2]f32 {
    const area = screen();
    const clip = view_proj.mulVec4(.{ world_position[0], world_position[1], world_position[2], 1 });
    if (clip[3] <= 0.001) return null;
    const ndc = clip / @as(nz.Vec4(f32), @splat(clip[3]));
    if (ndc[0] < -1 or ndc[0] > 1 or ndc[1] < -1 or ndc[1] > 1 or ndc[2] < 0 or ndc[2] > 1) return null;
    return .{ (ndc[0] * 0.5 + 0.5) * area.w, (ndc[1] * 0.5 + 0.5) * area.h };
}

pub fn texture(handle: contract.TextureHandle) dvui.Texture {
    return Backend.textureFor(handle, 64, 64);
}

pub fn bar(rect: dvui.Rect, fraction: f32, fill: dvui.Color) void {
    fillRect(rect, .{ .r = 0, .g = 0, .b = 0, .a = 140 });
    fillRect(.{ .x = rect.x, .y = rect.y, .w = rect.w * std.math.clamp(fraction, 0, 1), .h = rect.h }, fill);
}

pub fn wrapped(src: std.builtin.SourceLocation, content: []const u8, size: f32, color: dvui.Color) void {
    var layout = dvui.textLayout(src, .{}, .{
        .expand = .horizontal,
        .background = false,
        .font = font(size),
        .color_text = .fromColor(color),
        .padding = .{ .y = 2, .h = 6 },
    });
    layout.addText(content, .{});
    layout.deinit();
}
