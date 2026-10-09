const std = @import("std");
const dvui = @import("dvui");
const World = @import("../World.zig");

const text: dvui.Color = .{ .r = 240, .g = 245, .b = 230 };
const dim: dvui.Color = .{ .r = 168, .g = 178, .b = 173 };
const control: dvui.Color = .{ .r = 15, .g = 17, .b = 14, .a = 245 };
const accent: dvui.Color = .{ .r = 224, .g = 140, .b = 20 };
const danger: dvui.Color = .{ .r = 217, .g = 31, .b = 20 };

pub fn update(world: *World, following: ?usize) bool {
    const options = &world.options;
    const area = dvui.windowRect();
    dvui.windowRectPixels().fill(.all(0), .{ .color = .fromColor(.{ .r = 0, .g = 0, .b = 0, .a = 133 }) });
    const width: f32 = 400;
    const height: f32 = 380;
    var panel = dvui.box(@src(), .{ .dir = .vertical }, .{
        .rect = .{ .x = (area.w - width) / 2, .y = (area.h - height) / 2, .w = width, .h = height },
        .background = true,
        .color_fill = .fromColor(.{ .r = 5, .g = 6, .b = 6, .a = 235 }),
        .padding = .all(18),
    });
    defer panel.deinit();
    dvui.labelNoFmt(@src(), "Server View", .{}, .{ .font = font(34), .color_text = .fromColor(text), .gravity_x = 0.5 });
    if (following) |index| {
        dvui.label(@src(), "following player {d}/{d}", .{ index + 1, world.players.items.len }, .{ .font = font(18), .color_text = .fromColor(dim), .gravity_x = 0.5 });
    } else {
        dvui.label(@src(), "free camera - {d} connected", .{world.players.items.len}, .{ .font = font(18), .color_text = .fromColor(dim), .gravity_x = 0.5 });
    }
    if (button(@src(), if (options.draw_flow_field) "Draw Flow Field: On" else "Draw Flow Field: Off", control)) options.draw_flow_field = !options.draw_flow_field;
    if (button(@src(), if (options.draw_chunk_borders) "Draw Chunk Borders: On" else "Draw Chunk Borders: Off", control)) options.draw_chunk_borders = !options.draw_chunk_borders;
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 0, .h = 40 } });
    return button(@src(), "Close Server", danger.lerp(.black, 0.6));
}

fn font(size: f32) dvui.Font {
    return dvui.Font.theme(.body).withSize(size);
}

fn button(src: std.builtin.SourceLocation, label: []const u8, fill: dvui.Color) bool {
    return dvui.button(src, label, .{ .draw_focus = false }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 0, .h = 40 },
        .font = font(22),
        .color_fill = .fromColor(fill),
        .color_fill_hover = .fromColor(accent),
        .color_text = .fromColor(text),
        .color_text_hover = .fromColor(.black),
        .corners = .all(0),
        .margin = .{ .y = 4, .h = 4 },
    });
}
