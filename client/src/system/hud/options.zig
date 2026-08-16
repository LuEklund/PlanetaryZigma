const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const system = @import("../../System.zig");
const World = system.World;
const Ui = @import("ui");
const NetworkManager = @import("../NetworkManager.zig");
const Controller = @import("../Controller.zig");
const Options = @import("../../Options.zig");
const Hud = @import("../Hud.zig");
const Request = Hud.Request;
const OptionsTab = Hud.OptionsTab;

pub fn update(ui: *Ui, hud: *Hud, options: *Options, controller: *Controller) void {
    const max_width = @max(@as(f32, 260), ui.screen_width - 8);
    const max_height = @max(@as(f32, 320), ui.screen_height - 8);
    const panel_width = @min(max_width, @max(@as(f32, 740), ui.screen_width * 0.9));
    const panel_height = @min(max_height, @max(@as(f32, 460), ui.screen_height * 0.88));
    const left = (ui.screen_width - panel_width) * 0.5;
    const top = (ui.screen_height - panel_height) * 0.5;
    const padding = std.math.clamp(panel_width * 0.035, @as(f32, 18), @as(f32, 30));
    const content_left = left + padding;
    const content_width = panel_width - padding * 2;
    const title_height: f32 = 52;
    const tab_gap: f32 = 6;
    const tab_height: f32 = 36;
    const tabs = [_]OptionsTab{ .gameplay, .keyboard_mouse, .video, .graphics };
    const tab_width = (content_width - tab_gap * @as(f32, @floatFromInt(tabs.len - 1))) / @as(f32, @floatFromInt(tabs.len));
    const tabs_top = top + padding + title_height;
    const body_top = tabs_top + tab_height + 18;
    const body_height = panel_height - (body_top - top) - padding - 48;

    ui.add(null, .{
        .size = .{ .percent = .{ .width = 1, .height = 1 } },
        .color = .new(0, 0, 0, 0.52),
    });
    ui.add(null, .{
        .name = "options_panel",
        .size = .{ .fixed = .{ .width = panel_width, .height = panel_height } },
        .offset = .{ .left = left, .top = top },
        .color = .new(0.02, 0.025, 0.025, 0.92),
    });
    ui.add(null, .{
        .size = .{ .fixed = .{ .width = content_width, .height = title_height } },
        .offset = .{ .left = content_left, .top = top + padding },
        .child_anchor = .{ .x = .center, .y = .center },
        .text = .{ .data = "Options", .size = 34, .color = .new(0.94, 0.96, 0.9, 1) },
    });

    for (tabs, 0..) |tab, i| {
        const tab_left = content_left + (tab_width + tab_gap) * @as(f32, @floatFromInt(i));
        addOptionsTab(ui, tab, hud.options_tab == tab, tab_left, tabs_top, tab_width, tab_height);
        if (ui.isClicked(optionsTabName(tab))) hud.options_tab = tab;
    }

    switch (hud.options_tab) {
        .gameplay => optionsGameplay(ui, options, content_left, body_top, content_width),
        .keyboard_mouse => optionsKeyboardMouse(ui, options, controller, content_left, body_top, content_width),
        .video => optionsVideo(ui, options, content_left, body_top, content_width),
        .graphics => optionsGraphics(ui, controller, content_left, body_top, content_width),
    }

    const back_width: f32 = 150;
    addOptionsButton(ui, "options_back", "Back", content_left + content_width - back_width, body_top + body_height, back_width, 40);
    if (ui.isClicked("options_back")) {
        hud.overlay = if (hud.overlay.options.return_to_pause) .pause else .none;
    }
}

fn optionsGameplay(ui: *Ui, options: *Options, left: f32, top: f32, width: f32) void {
    const row_height: f32 = 44;
    if (addOptionToggle(ui, "options_crosshair", "Crosshair", boolText(options.show_crosshair), left, top, width, row_height)) {
        options.show_crosshair = !options.show_crosshair;
    }
}

fn optionsKeyboardMouse(ui: *Ui, options: *Options, controller: *Controller, left: f32, top: f32, width: f32) void {
    const slider_height: f32 = 38;
    const toggle_height: f32 = 32;
    const binding_height: f32 = 26;
    const binding_gap: f32 = 3;
    if (addOptionSlider(ui, "options_mouse_sensitivity", "Mouse Sensitivity", options.mouse_sensitivity, 0.25, 3.0, left, top, width, slider_height, ui.print("{d:.2}x", .{options.mouse_sensitivity}))) |value| {
        options.mouse_sensitivity = value;
    }
    if (addOptionToggle(ui, "options_invert_y", "Invert Y", boolText(options.invert_y), left, top + slider_height + 6, width, toggle_height)) {
        options.invert_y = !options.invert_y;
    }

    const bindings_top = top + slider_height + toggle_height + 18;
    const column_gap: f32 = 14;
    const column_width = (width - column_gap) * 0.5;
    var listed: usize = 0;
    for (std.enums.values(Controller.ActionKind)) |action| {
        const bindable = Controller.bindable.get(action) orelse continue;
        const column: f32 = if (listed < 6) 0 else 1;
        const row: f32 = @floatFromInt(if (listed < 6) listed else listed - 6);
        const row_left = left + column * (column_width + column_gap);
        const row_top = bindings_top + row * (binding_height + binding_gap);
        if (addBindingRow(ui, controller, action, bindable, row_left, row_top, column_width, binding_height)) {
            controller.rebinding_action = action;
            controller.rebinding_fresh = true;
        }
        listed += 1;
    }
}

fn optionsVideo(ui: *Ui, options: *Options, left: f32, top: f32, width: f32) void {
    const row_height: f32 = 44;
    const row_gap: f32 = 10;
    if (addOptionToggle(ui, "options_fullscreen", "Fullscreen", boolText(options.fullscreen), left, top, width, row_height)) {
        options.fullscreen = !options.fullscreen;
    }
    const fov_degrees = options.fov_rad * 180.0 / std.math.pi;
    if (addOptionSlider(ui, "options_fov", "Field of View", fov_degrees, 65, 115, left, top + (row_height + row_gap), width, row_height, ui.print("{d:.0}", .{fov_degrees}))) |value| {
        options.fov_rad = value * std.math.pi / 180.0;
    }
    if (addOptionSlider(ui, "options_chunk_view_distance", "Chunk View Distance", options.chunk_view_distance, 1, 8, left, top + 2 * (row_height + row_gap), width, row_height, ui.print("{d:.0}", .{options.chunk_view_distance}))) |value| {
        options.chunk_view_distance = @round(value);
    }
}

fn optionsGraphics(ui: *Ui, controller: *Controller, left: f32, top: f32, width: f32) void {
    const row_height: f32 = 44;
    if (addOptionToggle(ui, "options_debug_colliders", "Debug Colliders", boolText(controller.debug_draw_colliders), left, top, width, row_height)) {
        controller.debug_draw_colliders = !controller.debug_draw_colliders;
    }
}

fn addOptionsTab(ui: *Ui, tab: OptionsTab, selected: bool, left: f32, top: f32, width: f32, height: f32) void {
    const name = optionsTabName(tab);
    const hot = ui.isHot(name);
    ui.add(null, .{
        .name = name,
        .size = .{ .fixed = .{ .width = width, .height = height } },
        .offset = .{ .left = left, .top = top },
        .color = if (selected or hot) .new(0.88, 0.55, 0.08, 0.96) else .new(0.06, 0.065, 0.055, 0.96),
        .child_anchor = .{ .x = .center, .y = .center },
        .text = .{
            .data = optionsTabLabel(tab),
            .size = std.math.clamp(width * 0.115, @as(f32, 12), @as(f32, 15)),
            .color = if (selected or hot) .new(0.02, 0.02, 0.015, 1) else .new(0.94, 0.96, 0.9, 1),
        },
    });
}

fn addOptionToggle(ui: *Ui, name: []const u8, label: []const u8, value: []const u8, left: f32, top: f32, width: f32, height: f32) bool {
    const value_width = std.math.clamp(width * 0.32, @as(f32, 150), @as(f32, 220));
    const label_width = width - value_width - 14;
    ui.add(null, .{
        .size = .{ .fixed = .{ .width = width, .height = height } },
        .offset = .{ .left = left, .top = top },
        .color = .new(0.035, 0.04, 0.038, 0.82),
    });
    ui.add(null, .{
        .size = .{ .fixed = .{ .width = label_width, .height = height } },
        .offset = .{ .left = left + 14, .top = top },
        .child_anchor = .{ .x = .start, .y = .center },
        .text = .{ .data = label, .size = 22, .color = .new(0.9, 0.93, 0.86, 1) },
    });
    addOptionsButton(ui, name, value, left + width - value_width, top + 5, value_width - 8, height - 10);
    return ui.isClicked(name);
}

fn addBindingRow(ui: *Ui, controller: *Controller, action: Controller.ActionKind, label: []const u8, left: f32, top: f32, width: f32, height: f32) bool {
    const name = bindingRowName(action);
    const value = if (controller.rebinding_action == action) "Listening" else Controller.bindingLabel(controller.bindings.get(action));
    return addOptionToggle(ui, name, label, value, left, top, width, height);
}

fn addOptionSlider(ui: *Ui, name: []const u8, label: []const u8, value: f32, min: f32, max: f32, left: f32, top: f32, width: f32, height: f32, value_text: []const u8) ?f32 {
    const value_width = std.math.clamp(width * 0.2, @as(f32, 82), @as(f32, 130));
    const label_width = std.math.clamp(width * 0.28, @as(f32, 160), @as(f32, 230));
    const track_left = left + label_width + 16;
    const track_width = width - label_width - value_width - 34;
    const track_height = @max(@as(f32, 8), height * 0.24);
    const track_top = top + (height - track_height) * 0.5;
    const normalized = std.math.clamp((value - min) / (max - min), @as(f32, 0), @as(f32, 1));

    ui.add(null, .{
        .size = .{ .fixed = .{ .width = width, .height = height } },
        .offset = .{ .left = left, .top = top },
        .color = .new(0.035, 0.04, 0.038, 0.82),
    });
    ui.add(null, .{
        .size = .{ .fixed = .{ .width = label_width, .height = height } },
        .offset = .{ .left = left + 14, .top = top },
        .child_anchor = .{ .x = .start, .y = .center },
        .text = .{ .data = label, .size = 20, .color = .new(0.9, 0.93, 0.86, 1) },
    });
    ui.add(null, .{
        .size = .{ .fixed = .{ .width = track_width, .height = track_height } },
        .offset = .{ .left = track_left, .top = track_top },
        .color = .new(0.09, 0.1, 0.095, 1),
    });
    ui.add(null, .{
        .size = .{ .fixed = .{ .width = track_width * normalized, .height = track_height } },
        .offset = .{ .left = track_left, .top = track_top },
        .color = .new(0.88, 0.55, 0.08, 0.96),
    });
    ui.add(null, .{
        .size = .{ .fixed = .{ .width = 10, .height = height - 10 } },
        .offset = .{ .left = track_left + track_width * normalized - 5, .top = top + 5 },
        .color = .new(0.94, 0.96, 0.9, 1),
    });
    ui.add(null, .{
        .size = .{ .fixed = .{ .width = value_width, .height = height - 8 } },
        .offset = .{ .left = left + width - value_width, .top = top + 4 },
        .color = .new(0.06, 0.065, 0.055, 0.96),
        .child_anchor = .{ .x = .center, .y = .center },
        .text = .{ .data = value_text, .size = 20, .color = .new(0.94, 0.96, 0.9, 1) },
    });
    ui.add(null, .{
        .name = name,
        .size = .{ .fixed = .{ .width = track_width, .height = height } },
        .offset = .{ .left = track_left, .top = top },
        .color = .new(0, 0, 0, 0),
    });

    if (!ui.isDragging(name)) return null;
    const mouse_x = std.math.clamp(ui.mouse_state.position.left, track_left, track_left + track_width);
    const next = min + ((mouse_x - track_left) / track_width) * (max - min);
    return next;
}

fn bindingRowName(action: Controller.ActionKind) []const u8 {
    return switch (action) {
        inline else => |inline_action| "bind_" ++ @tagName(inline_action),
    };
}

fn optionsTabName(tab: OptionsTab) []const u8 {
    return switch (tab) {
        .gameplay => "options_tab_gameplay",
        .keyboard_mouse => "options_tab_keyboard_mouse",
        .video => "options_tab_video",
        .graphics => "options_tab_graphics",
    };
}

fn optionsTabLabel(tab: OptionsTab) []const u8 {
    return switch (tab) {
        .gameplay => "Gameplay",
        .keyboard_mouse => "Keyboard-Mouse",
        .video => "Video",
        .graphics => "Graphics",
    };
}

fn boolText(value: bool) []const u8 {
    return if (value) "On" else "Off";
}

fn addOptionsButton(ui: *Ui, name: []const u8, text: []const u8, left: f32, top: f32, width: f32, height: f32) void {
    const hot = ui.isHot(name);
    ui.add(null, .{
        .name = name,
        .size = .{ .fixed = .{ .width = width, .height = height } },
        .offset = .{ .left = left, .top = top },
        .color = if (hot) .new(0.88, 0.55, 0.08, 0.96) else .new(0.06, 0.065, 0.055, 0.96),
        .child_anchor = .{ .x = .center, .y = .center },
        .text = .{
            .data = text,
            .size = std.math.clamp(height * 0.52, @as(f32, 21), @as(f32, 27)),
            .color = if (hot) .new(0.02, 0.02, 0.015, 1) else .new(0.94, 0.96, 0.9, 1),
        },
    });
}
