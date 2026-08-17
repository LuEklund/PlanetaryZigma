const std = @import("std");
const Ui = @import("ui");
const Hud = @import("../Hud.zig");
const Request = Hud.Request;

pub fn update(ui: *Ui, hud: *Hud) !Request {
    const panel_width = std.math.clamp(ui.screen_width * 0.28, @as(f32, 260), @as(f32, 360));
    const button_height = std.math.clamp(ui.screen_height * 0.058, @as(f32, 40), @as(f32, 52));
    const row_gap: f32 = 10;
    const title_height: f32 = 56;
    const panel_padding = std.math.clamp(ui.screen_height * 0.018, @as(f32, 14), @as(f32, 22));
    const content_height = title_height + button_height * 3 + row_gap * 3;
    const panel_height = content_height + panel_padding * 2;
    const left = (ui.screen_width - panel_width) * 0.5;
    const top = (ui.screen_height - panel_height) * 0.5;

    ui.add(null, .{
        .size = .{ .percent = .{ .width = 1, .height = 1 } },
        .color = .new(0, 0, 0, 0.52),
    });
    ui.add(null, .{
        .name = "pause_panel",
        .size = .{ .fixed = .{ .width = panel_width, .height = panel_height } },
        .offset = .{ .left = left, .top = top },
        .color = .new(0.02, 0.025, 0.025, 0.92),
        .axis_align = .vertical,
        .child_anchor = .{ .x = .center, .y = .center },
        .gap = row_gap,
    });
    ui.add("pause_panel", .{
        .size = .{ .fixed = .{ .width = panel_width, .height = title_height } },
        .child_anchor = .{ .x = .center, .y = .center },
        .text = .{ .data = "Paused", .size = 34, .color = .new(0.94, 0.96, 0.9, 1) },
    });

    addPauseButton(ui, "pause_resume", "Resume", panel_width * 0.82, button_height);
    addPauseButton(ui, "pause_options", "Options", panel_width * 0.82, button_height);
    addPauseButton(ui, "pause_main_menu", "Main Menu", panel_width * 0.82, button_height);

    if (ui.isClicked("pause_resume")) {
        hud.overlay = .none;
    }
    if (ui.isClicked("pause_options")) {
        hud.overlay = .{ .options = .{ .return_to_pause = true } };
    }
    if (ui.isClicked("pause_main_menu")) {
        return .main_menu;
    }
    return .none;
}

fn addPauseButton(ui: *Ui, name: []const u8, text: []const u8, width: f32, height: f32) void {
    const hot = ui.isHot(name);
    ui.add("pause_panel", .{
        .name = name,
        .size = .{ .fixed = .{ .width = width, .height = height } },
        .color = if (hot) .new(0.88, 0.55, 0.08, 0.96) else .new(0.06, 0.065, 0.055, 0.96),
        .child_anchor = .{ .x = .center, .y = .center },
        .text = .{
            .data = text,
            .size = std.math.clamp(height * 0.52, @as(f32, 21), @as(f32, 27)),
            .color = if (hot) .new(0.02, 0.02, 0.015, 1) else .new(0.94, 0.96, 0.9, 1),
        },
    });
}
