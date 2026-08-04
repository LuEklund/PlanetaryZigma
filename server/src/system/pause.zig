const std = @import("std");
const Ui = @import("render").Ui;

pub const Request = enum { none, resume_view, quit };

/// The server view's only screen. The sim keeps ticking behind it — this releases the
/// mouse and offers a clean exit, nothing more.
pub fn update(ui: *Ui, player_count: usize, following: ?usize) Request {
    const panel_width = std.math.clamp(ui.screen_width * 0.28, @as(f32, 260), @as(f32, 360));
    const button_height = std.math.clamp(ui.screen_heigth * 0.058, @as(f32, 40), @as(f32, 52));
    const row_gap: f32 = 10;
    const title_height: f32 = 56;
    const status_height: f32 = 28;
    const panel_padding = std.math.clamp(ui.screen_heigth * 0.018, @as(f32, 14), @as(f32, 22));
    const panel_height = title_height + status_height + button_height * 2 + row_gap * 3 + panel_padding * 2;
    const left = (ui.screen_width - panel_width) * 0.5;
    const top = (ui.screen_heigth - panel_height) * 0.5;

    ui.add(null, .{
        .size = .{ .percent = .{ .width = 1, .heigth = 1 } },
        .color = .new(0, 0, 0, 0.52),
    });
    ui.add(null, .{
        .name = "server_pause_panel",
        .size = .{ .fixed = .{ .width = panel_width, .heigth = panel_height } },
        .offset = .{ .left = left, .top = top },
        .color = .new(0.02, 0.025, 0.025, 0.92),
        .axis_align = .vertical,
        .child_anchor = .{ .x = .center, .y = .center },
        .gap = row_gap,
    });
    ui.add("server_pause_panel", .{
        .size = .{ .fixed = .{ .width = panel_width, .heigth = title_height } },
        .child_anchor = .{ .x = .center, .y = .center },
        .text = .{ .data = "Server View", .size = 34, .color = .new(0.94, 0.96, 0.9, 1) },
    });
    ui.add("server_pause_panel", .{
        .size = .{ .fixed = .{ .width = panel_width, .heigth = status_height } },
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

    addButton(ui, "server_pause_resume", "Resume", panel_width * 0.82, button_height);
    addButton(ui, "server_pause_quit", "Quit Server", panel_width * 0.82, button_height);

    if (ui.isActive("server_pause_resume")) return .resume_view;
    if (ui.isActive("server_pause_quit")) return .quit;
    return .none;
}

fn addButton(ui: *Ui, name: []const u8, text: []const u8, width: f32, height: f32) void {
    const hot = ui.isHot(name);
    ui.add("server_pause_panel", .{
        .name = name,
        .size = .{ .fixed = .{ .width = width, .heigth = height } },
        .color = if (hot) .new(0.88, 0.55, 0.08, 0.96) else .new(0.06, 0.065, 0.055, 0.96),
        .child_anchor = .{ .x = .center, .y = .center },
        .text = .{
            .data = text,
            .size = std.math.clamp(height * 0.52, @as(f32, 21), @as(f32, 27)),
            .color = if (hot) .new(0.02, 0.02, 0.015, 1) else .new(0.94, 0.96, 0.9, 1),
        },
    });
}
