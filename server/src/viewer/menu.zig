const std = @import("std");
const Ui = @import("ui");
const World = @import("../World.zig");

/// Returns true when the menu asks the server to stop.
pub fn update(ui: *Ui, world: *World, following: ?usize) bool {
    const options = &world.options;
    const player_count = world.players.items.len;
    const panel_width = std.math.clamp(ui.screen_width * 0.34, @as(f32, 320), @as(f32, 460));
    const button_height = std.math.clamp(ui.screen_height * 0.058, @as(f32, 40), @as(f32, 52));
    const row_height: f32 = 44;
    const row_gap: f32 = 10;
    const title_height: f32 = 56;
    const status_height: f32 = 28;
    const panel_padding = std.math.clamp(ui.screen_height * 0.018, @as(f32, 14), @as(f32, 22));
    const quit_spacer: f32 = 60;
    const panel_height = title_height + status_height + row_height * 2 + quit_spacer + button_height + row_gap * 5 + panel_padding * 2;
    const left = (ui.screen_width - panel_width) * 0.5;
    const top = (ui.screen_height - panel_height) * 0.5;
    const row_width = panel_width * 0.82;

    ui.add(null, .{
        .size = .{ .percent = .{ .width = 1, .height = 1 } },
        .color = .new(0, 0, 0, 0.52),
    });
    ui.add(null, .{
        .name = "server_menu_panel",
        .size = .{ .fixed = .{ .width = panel_width, .height = panel_height } },
        .offset = .{ .left = left, .top = top },
        .color = .new(0.02, 0.025, 0.025, 0.92),
        .axis_align = .vertical,
        .child_anchor = .{ .x = .center, .y = .center },
        .gap = row_gap,
    });
    ui.add("server_menu_panel", .{
        .size = .{ .fixed = .{ .width = panel_width, .height = title_height } },
        .child_anchor = .{ .x = .center, .y = .center },
        .text = .{ .data = "Server View", .size = 34, .color = .new(0.94, 0.96, 0.9, 1) },
    });
    ui.add("server_menu_panel", .{
        .size = .{ .fixed = .{ .width = panel_width, .height = status_height } },
        .child_anchor = .{ .x = .center, .y = .center },
        .text = .{
            .data = if (following) |index|
                ui.print("following player {d}/{d}", .{ index + 1, player_count })
            else
                ui.print("free camera — {d} connected", .{player_count}),
            .size = 18,
            .color = .new(0.66, 0.7, 0.68, 1),
        },
    });

    if (ui.addToggle("server_menu_panel", "server_menu_draw_flow_field", "Draw Flow Field", options.draw_flow_field, 0, 0, row_width, row_height))
        options.draw_flow_field = !options.draw_flow_field;
    if (ui.addToggle("server_menu_panel", "server_menu_draw_chunk_borders", "Draw Chunk Borders", options.draw_chunk_borders, 0, 0, row_width, row_height))
        options.draw_chunk_borders = !options.draw_chunk_borders;
    ui.add("server_menu_panel", .{ .size = .{ .fixed = .{ .width = row_width, .height = quit_spacer } } });
    const quit_hovered = ui.isHovered("server_menu_quit");
    ui.add("server_menu_panel", .{
        .name = "server_menu_quit",
        .size = .{ .fixed = .{ .width = row_width, .height = button_height } },
        .color = if (quit_hovered) .new(0.85, 0.12, 0.08, 0.96) else .new(0.3, 0.04, 0.03, 0.96),
        .child_anchor = .{ .x = .center, .y = .center },
        .text = .{
            .data = "Close Server",
            .size = std.math.clamp(button_height * 0.52, @as(f32, 21), @as(f32, 27)),
            .color = if (quit_hovered) .new(0.02, 0.02, 0.015, 1) else .new(0.94, 0.9, 0.88, 1),
        },
    });

    return ui.isClicked("server_menu_quit");
}
