const std = @import("std");
const nz = @import("shared").numz;
const shared = @import("shared");
const system = @import("../system.zig");
const tracy = @import("ztracy");
const Info = system.Info;
const Ui = @import("../Renderer/Vulkan/Ui.zig");
const NetworkManager = @import("NetworkManager.zig");
const Controller = @import("Controller.zig");

pub fn update(info: *const Info, network_manager: *NetworkManager, ui: *Ui, controller: *const Controller) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();

    const position: [2]f32 = .{ @floatCast(controller.mouse_pos[0]), @floatCast(controller.mouse_pos[1]) };
    ui.start(.{
        .position = .{ .left = position[0], .top = position[1] },
        .left_click = controller.mouse_button_left,
        .right_click = controller.mouse_button_right,
    });
    if (network_manager.steam_client.server_conn == 0) {
        info.world.show_menu_scene = true;
        try mainMenu(info, network_manager, ui);
        if (info.world.options_menu_open) optionsMenu(info, ui);
    } else {
        info.world.show_menu_scene = false;
        try inGame(info, ui);
        if (info.world.pause_menu_open) {
            try pauseMenu(info, network_manager, ui);
        } else if (info.world.options_menu_open) {
            optionsMenu(info, ui);
        }
    }

    ui.end();
}

fn mainMenu(info: *const Info, network_manager: *NetworkManager, ui: *Ui) !void {
    const button_width = std.math.clamp(ui.screen_width * 0.155, @as(f32, 216), @as(f32, 320));
    const button_height = std.math.clamp(ui.screen_heigth * 0.048, @as(f32, 36), @as(f32, 46));
    const button_gap = std.math.clamp(ui.screen_heigth * 0.012, @as(f32, 7), @as(f32, 11));
    const button_text_size = std.math.clamp(button_height * 0.55, @as(f32, 20), @as(f32, 25));
    const left = std.math.clamp(ui.screen_width * 0.07, @as(f32, 48), @as(f32, 132));
    const total_height = button_height * 4 + button_gap * 3;
    const max_top = @max(@as(f32, 28), ui.screen_heigth - total_height - 28);
    const top = std.math.clamp((ui.screen_heigth - total_height) * 0.5, @as(f32, 28), max_top);
    const panel_gap = std.math.clamp(ui.screen_width * 0.025, @as(f32, 24), @as(f32, 48));
    const panel_left = if (ui.screen_width < 760) left else left + button_width + panel_gap;
    const panel_top = if (ui.screen_width < 760) top + total_height + 20 else top;
    const panel_width = @max(@as(f32, 280), ui.screen_width - panel_left - left);
    const steam_logged_on = network_manager.steam_logged_on;
    const singleplayer_hosting = network_manager.host_intent == .singleplayer and
        (network_manager.host_state == .requested or network_manager.host_state == .waiting or network_manager.host_state == .hosting);
    const singleplayer_failed = network_manager.host_intent == .singleplayer and network_manager.host_state == .failed;
    const singleplayer_text = if (singleplayer_hosting) "Starting..." else if (singleplayer_failed) "Start Failed" else "Singleplayer";

    addMainMenuButton(ui, "menu_singleplayer", singleplayer_text, left, top, button_width, button_height, button_text_size, singleplayer_hosting, true);
    addMainMenuButton(ui, "menu_multiplayer", "Multiplayer", left, top + (button_height + button_gap), button_width, button_height, button_text_size, info.world.menu_screen == .multiplayer, steam_logged_on);
    addMainMenuButton(ui, "menu_settings", "Options", left, top + (button_height + button_gap) * 2, button_width, button_height, button_text_size, info.world.options_menu_open, true);
    addMainMenuButton(ui, "menu_quit", "Quit to Desktop", left, top + (button_height + button_gap) * 3, button_width, button_height, button_text_size, false, true);

    if (ui.isActive("menu_singleplayer")) {
        info.world.menu_screen = .main;
        network_manager.requestHost(.singleplayer);
    }
    if (steam_logged_on and ui.isActive("menu_multiplayer")) {
        info.world.menu_screen = .multiplayer;
        if (!network_manager.server_list.refresh and network_manager.server_list.count == 0) {
            network_manager.server_list.refresh = true;
        }
    } else if (!steam_logged_on and ui.isActive("menu_multiplayer")) {
        info.world.menu_screen = .multiplayer;
    }
    if (ui.isActive("menu_settings")) {
        info.world.menu_screen = .main;
        info.world.options_menu_open = true;
        info.world.options_menu_return_to_pause = false;
    }
    if (ui.isActive("menu_quit")) {
        info.world.request_quit = true;
    }

    switch (info.world.menu_screen) {
        .main => {},
        .multiplayer => try multiplayerPanel(network_manager, ui, panel_left, panel_top, panel_width),
    }
}

fn addMainMenuButton(ui: *Ui, name: []const u8, text: []const u8, left: f32, top: f32, width: f32, height: f32, text_size: f32, selected: bool, enabled: bool) void {
    const hot = enabled and ui.isHot(name);
    const bg = if (!enabled)
        nz.color.Rgba(f32).new(0.045, 0.048, 0.045, 1)
    else if (selected or hot)
        nz.color.Rgba(f32).new(0.88, 0.55, 0.08, 1)
    else
        nz.color.Rgba(f32).new(0.02, 0.025, 0.025, 1);
    const fg = if (!enabled)
        nz.color.Rgba(f32).new(0.44, 0.46, 0.42, 1)
    else if (selected or hot)
        nz.color.Rgba(f32).new(0.02, 0.02, 0.015, 1)
    else
        nz.color.Rgba(f32).new(0.94, 0.96, 0.9, 1);

    ui.add(null, .{
        .name = name,
        .size = .{ .fixed = .{ .heigth = height, .width = width } },
        .offset = .{ .left = left, .top = top },
        .color = bg,
        .child_anchor = .{ .x = .center, .y = .center },
        .text = .{ .data = text, .size = text_size, .color = fg },
    });
}

fn multiplayerPanel(network_manager: *NetworkManager, ui: *Ui, left: f32, top: f32, width: f32) !void {
    const row_height: f32 = 42;
    const row_gap: f32 = 8;
    const panel_width = @max(@as(f32, 260), width);
    const button_width = (panel_width - row_gap) * 0.5;
    const hosting = network_manager.host_state == .requested or network_manager.host_state == .waiting or network_manager.host_state == .hosting;
    const host_failed = network_manager.host_state == .failed;
    const steam_logged_on = network_manager.steam_logged_on;

    ui.add(null, .{
        .name = "menu_refresh",
        .size = .{ .fixed = .{ .heigth = row_height, .width = button_width } },
        .offset = .{ .left = left, .top = top },
        .color = if (!steam_logged_on) .new(0.045, 0.048, 0.045, 0.82) else if (ui.isHot("menu_refresh")) .new(0.14, 0.14, 0.12, 0.92) else .new(0.02, 0.025, 0.025, 0.82),
        .child_anchor = .{ .x = .center, .y = .center },
        .text = .{ .data = "Refresh Servers", .size = 26, .color = if (steam_logged_on) .new(0.94, 0.96, 0.9, 1) else .new(0.44, 0.46, 0.42, 1) },
    });
    if (steam_logged_on and ui.isActive("menu_refresh") and network_manager.server_list.refresh == false) {
        network_manager.server_list.refresh = true;
    }
    ui.add(null, .{
        .name = "menu_host",
        .size = .{ .fixed = .{ .heigth = row_height, .width = button_width } },
        .offset = .{ .left = left + button_width + row_gap, .top = top },
        .color = if (!steam_logged_on) .new(0.045, 0.048, 0.045, 0.82) else if (hosting or ui.isHot("menu_host")) .new(0.88, 0.55, 0.08, 0.96) else .new(0.02, 0.025, 0.025, 0.82),
        .child_anchor = .{ .x = .center, .y = .center },
        .text = .{
            .data = if (!steam_logged_on) "Steam Offline" else if (hosting) "Hosting..." else if (host_failed) "Host Failed" else "Host",
            .size = 26,
            .color = if (!steam_logged_on) .new(0.44, 0.46, 0.42, 1) else if (hosting or ui.isHot("menu_host")) .new(0.02, 0.02, 0.015, 1) else .new(0.94, 0.96, 0.9, 1),
        },
    });
    if (ui.isActive("menu_host") and (network_manager.host_state == .none or network_manager.host_state == .failed or network_manager.host_state == .steam_offline)) {
        network_manager.requestHost(.multiplayer);
    }

    if (network_manager.server_list.count == 0) {
        ui.add(null, .{
            .size = .{ .fixed = .{ .heigth = row_height, .width = panel_width } },
            .offset = .{ .left = left, .top = top + row_height + row_gap },
            .color = .new(0.02, 0.025, 0.025, 0.62),
            .child_anchor = .{ .x = .center, .y = .center },
            .text = .{
                .data = if (!steam_logged_on) "Steam is offline" else if (hosting) "Hosting..." else if (network_manager.server_list.refresh) "Searching for servers" else "No servers found",
                .size = 24,
                .color = .new(0.68, 0.72, 0.66, 1),
            },
        });
        return;
    }

    const max_rows = @min(network_manager.server_list.count, network_manager.server_list.servers.len);
    for (0..max_rows) |i| {
        const server = &network_manager.server_list.servers[i];
        const label = ui.print("{d}", .{server.steam_id});
        const row_top = top + (row_height + row_gap) * @as(f32, @floatFromInt(i + 1));
        ui.add(null, .{
            .name = label,
            .size = .{ .fixed = .{ .heigth = row_height, .width = panel_width } },
            .offset = .{ .left = left, .top = row_top },
            .color = if (ui.isHot(label)) .new(0.88, 0.55, 0.08, 0.96) else .new(0.02, 0.025, 0.025, 0.82),
            .child_anchor = .{ .x = .center, .y = .center },
            .text = .{ .data = label, .size = 24, .color = .new(0.94, 0.96, 0.9, 1) },
        });
        if (ui.isActive(label)) {
            try network_manager.steam_client.connectToServer(server.steam_id);
            std.log.debug("connect to {d}", .{server.steam_id});
        }
    }
}

fn pauseMenu(info: *const Info, network_manager: *NetworkManager, ui: *Ui) !void {
    const panel_width = std.math.clamp(ui.screen_width * 0.28, @as(f32, 260), @as(f32, 360));
    const button_height = std.math.clamp(ui.screen_heigth * 0.058, @as(f32, 40), @as(f32, 52));
    const row_gap: f32 = 10;
    const title_height: f32 = 56;
    const panel_padding = std.math.clamp(ui.screen_heigth * 0.018, @as(f32, 14), @as(f32, 22));
    const content_height = title_height + button_height * 3 + row_gap * 3;
    const panel_height = content_height + panel_padding * 2;
    const left = (ui.screen_width - panel_width) * 0.5;
    const top = (ui.screen_heigth - panel_height) * 0.5;

    ui.add(null, .{
        .size = .{ .percent = .{ .width = 1, .heigth = 1 } },
        .color = .new(0, 0, 0, 0.52),
    });
    ui.add(null, .{
        .name = "pause_panel",
        .size = .{ .fixed = .{ .width = panel_width, .heigth = panel_height } },
        .offset = .{ .left = left, .top = top },
        .color = .new(0.02, 0.025, 0.025, 0.92),
        .axis_align = .verical,
        .child_anchor = .{ .x = .center, .y = .center },
        .gap = row_gap,
    });
    ui.add("pause_panel", .{
        .size = .{ .fixed = .{ .width = panel_width, .heigth = title_height } },
        .child_anchor = .{ .x = .center, .y = .center },
        .text = .{ .data = "Paused", .size = 34, .color = .new(0.94, 0.96, 0.9, 1) },
    });

    addPauseButton(ui, "pause_resume", "Resume", panel_width * 0.82, button_height);
    addPauseButton(ui, "pause_options", "Options", panel_width * 0.82, button_height);
    addPauseButton(ui, "pause_main_menu", "Main Menu", panel_width * 0.82, button_height);

    if (ui.isActive("pause_resume")) {
        info.world.pause_menu_open = false;
    }
    if (ui.isActive("pause_options")) {
        info.world.pause_menu_open = false;
        info.world.options_menu_open = true;
        info.world.options_menu_return_to_pause = true;
    }
    if (ui.isActive("pause_main_menu")) {
        try network_manager.returnToMainMenu(info);
    }
}

fn optionsMenu(info: *const Info, ui: *Ui) void {
    const max_width = @max(@as(f32, 260), ui.screen_width - 8);
    const max_height = @max(@as(f32, 320), ui.screen_heigth - 8);
    const panel_width = @min(max_width, @max(@as(f32, 740), ui.screen_width * 0.9));
    const panel_height = @min(max_height, @max(@as(f32, 460), ui.screen_heigth * 0.88));
    const left = (ui.screen_width - panel_width) * 0.5;
    const top = (ui.screen_heigth - panel_height) * 0.5;
    const padding = std.math.clamp(panel_width * 0.035, @as(f32, 18), @as(f32, 30));
    const content_left = left + padding;
    const content_width = panel_width - padding * 2;
    const title_height: f32 = 52;
    const tab_gap: f32 = 6;
    const tab_height: f32 = 36;
    const tab_width = (content_width - tab_gap * 5) / 6;
    const tabs_top = top + padding + title_height;
    const body_top = tabs_top + tab_height + 18;
    const body_height = panel_height - (body_top - top) - padding - 48;

    ui.add(null, .{
        .size = .{ .percent = .{ .width = 1, .heigth = 1 } },
        .color = .new(0, 0, 0, 0.52),
    });
    ui.add(null, .{
        .name = "options_panel",
        .size = .{ .fixed = .{ .width = panel_width, .heigth = panel_height } },
        .offset = .{ .left = left, .top = top },
        .color = .new(0.02, 0.025, 0.025, 0.92),
    });
    ui.add(null, .{
        .size = .{ .fixed = .{ .width = content_width, .heigth = title_height } },
        .offset = .{ .left = content_left, .top = top + padding },
        .child_anchor = .{ .x = .center, .y = .center },
        .text = .{ .data = "Options", .size = 34, .color = .new(0.94, 0.96, 0.9, 1) },
    });

    const tabs = [_]system.World.OptionsTab{ .gameplay, .keyboard_mouse, .controller, .audio, .video, .graphics };
    for (tabs, 0..) |tab, i| {
        const tab_left = content_left + (tab_width + tab_gap) * @as(f32, @floatFromInt(i));
        addOptionsTab(ui, tab, info.world.options.tab == tab, tab_left, tabs_top, tab_width, tab_height);
        if (ui.isClicked(optionsTabName(tab))) info.world.options.tab = tab;
    }

    switch (info.world.options.tab) {
        .gameplay => optionsGameplay(info, ui, content_left, body_top, content_width),
        .keyboard_mouse => optionsKeyboardMouse(info, ui, content_left, body_top, content_width),
        .controller => optionsController(info, ui, content_left, body_top, content_width),
        .audio => optionsAudio(info, ui, content_left, body_top, content_width),
        .video => optionsVideo(info, ui, content_left, body_top, content_width),
        .graphics => optionsGraphics(info, ui, content_left, body_top, content_width),
    }

    const back_width: f32 = 150;
    addOptionsButton(ui, "options_back", "Back", content_left + content_width - back_width, body_top + body_height, back_width, 40);
    if (ui.isClicked("options_back")) {
        info.world.options_menu_open = false;
        if (info.world.options_menu_return_to_pause) {
            info.world.pause_menu_open = true;
        }
        info.world.options_menu_return_to_pause = false;
    }
}

fn optionsGameplay(info: *const Info, ui: *Ui, left: f32, top: f32, width: f32) void {
    const row_height: f32 = 44;
    const row_gap: f32 = 10;
    if (addOptionToggle(ui, "options_auto_sprint", "Auto Sprint", boolText(info.world.options.auto_sprint), left, top, width, row_height)) {
        info.world.options.auto_sprint = !info.world.options.auto_sprint;
    }
    if (addOptionToggle(ui, "options_hud_stats", "HUD Stats", boolText(info.world.options.show_hud_stats), left, top + (row_height + row_gap), width, row_height)) {
        info.world.options.show_hud_stats = !info.world.options.show_hud_stats;
    }
    if (addOptionToggle(ui, "options_crosshair", "Crosshair", boolText(info.world.options.show_crosshair), left, top + (row_height + row_gap) * 2, width, row_height)) {
        info.world.options.show_crosshair = !info.world.options.show_crosshair;
    }
}

fn optionsKeyboardMouse(info: *const Info, ui: *Ui, left: f32, top: f32, width: f32) void {
    const slider_height: f32 = 38;
    const toggle_height: f32 = 32;
    const binding_height: f32 = 26;
    const binding_gap: f32 = 3;
    if (addOptionSlider(ui, "options_mouse_sensitivity", "Mouse Sensitivity", info.world.options.mouse_sensitivity, 0.25, 3.0, left, top, width, slider_height, ui.print("{d:.2}x", .{info.world.options.mouse_sensitivity}))) |value| {
        info.world.options.mouse_sensitivity = value;
    }
    if (addOptionToggle(ui, "options_invert_y", "Invert Y", boolText(info.world.options.invert_y), left, top + slider_height + 6, width, toggle_height)) {
        info.world.options.invert_y = !info.world.options.invert_y;
    }

    const bindings_top = top + slider_height + toggle_height + 18;
    const column_gap: f32 = 14;
    const column_width = (width - column_gap) * 0.5;
    for (Controller.bindable_actions, 0..) |action, i| {
        const column: f32 = if (i < 6) 0 else 1;
        const row: f32 = @floatFromInt(if (i < 6) i else i - 6);
        const row_left = left + column * (column_width + column_gap);
        const row_top = bindings_top + row * (binding_height + binding_gap);
        if (addBindingRow(ui, &info.world.controller, action, row_left, row_top, column_width, binding_height)) {
            info.world.controller.rebinding_action = action;
            info.world.controller.clearInput();
        }
    }
}

fn optionsController(info: *const Info, ui: *Ui, left: f32, top: f32, width: f32) void {
    const diagram_height: f32 = 185;
    addControllerDiagram(ui, left, top, width, diagram_height);

    const row_height: f32 = 38;
    const row_gap: f32 = 8;
    const rows_top = top + diagram_height + 14;
    if (addOptionToggle(ui, "options_controller_input", "Controller Input", boolText(info.world.options.controller_enabled), left, rows_top, width, row_height)) {
        info.world.options.controller_enabled = !info.world.options.controller_enabled;
    }
    if (addOptionToggle(ui, "options_controller_vibration", "Vibration", boolText(info.world.options.controller_vibration), left, rows_top + (row_height + row_gap), width, row_height)) {
        info.world.options.controller_vibration = !info.world.options.controller_vibration;
    }
}

fn optionsAudio(info: *const Info, ui: *Ui, left: f32, top: f32, width: f32) void {
    const row_height: f32 = 44;
    if (addOptionToggle(ui, "options_master_volume", "Master Volume", ui.print("{d}%", .{info.world.options.master_volume}), left, top, width, row_height)) {
        info.world.options.cycleMasterVolume();
    }
}

fn optionsVideo(info: *const Info, ui: *Ui, left: f32, top: f32, width: f32) void {
    const row_height: f32 = 44;
    const row_gap: f32 = 10;
    if (addOptionToggle(ui, "options_fullscreen", "Fullscreen", boolText(info.world.options.fullscreen), left, top, width, row_height)) {
        info.world.options.fullscreen = !info.world.options.fullscreen;
    }
    const fov_degrees = info.world.options.fov_rad * 180.0 / std.math.pi;
    if (addOptionSlider(ui, "options_fov", "Field of View", fov_degrees, 65, 115, left, top + (row_height + row_gap), width, row_height, ui.print("{d:.0}", .{fov_degrees}))) |value| {
        info.world.options.fov_rad = value * std.math.pi / 180.0;
    }
}

fn optionsGraphics(info: *const Info, ui: *Ui, left: f32, top: f32, width: f32) void {
    const row_height: f32 = 44;
    if (addOptionToggle(ui, "options_debug_colliders", "Debug Colliders", boolText(info.world.controller.debug_draw_colliders), left, top, width, row_height)) {
        info.world.controller.debug_draw_colliders = !info.world.controller.debug_draw_colliders;
    }
}

fn addOptionsTab(ui: *Ui, tab: system.World.OptionsTab, selected: bool, left: f32, top: f32, width: f32, height: f32) void {
    const name = optionsTabName(tab);
    const hot = ui.isHot(name);
    ui.add(null, .{
        .name = name,
        .size = .{ .fixed = .{ .width = width, .heigth = height } },
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
        .size = .{ .fixed = .{ .width = width, .heigth = height } },
        .offset = .{ .left = left, .top = top },
        .color = .new(0.035, 0.04, 0.038, 0.82),
    });
    ui.add(null, .{
        .size = .{ .fixed = .{ .width = label_width, .heigth = height } },
        .offset = .{ .left = left + 14, .top = top },
        .child_anchor = .{ .x = .start, .y = .center },
        .text = .{ .data = label, .size = 22, .color = .new(0.9, 0.93, 0.86, 1) },
    });
    addOptionsButton(ui, name, value, left + width - value_width, top + 5, value_width - 8, height - 10);
    return ui.isClicked(name);
}

fn addBindingRow(ui: *Ui, controller: *Controller, action: Controller.Action, left: f32, top: f32, width: f32, height: f32) bool {
    const name = bindingRowName(action);
    const value = if (controller.rebinding_action == action) "Listening" else Controller.bindingLabel(controller.bindings.get(action));
    return addOptionToggle(ui, name, Controller.actionLabel(action), value, left, top, width, height);
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
        .size = .{ .fixed = .{ .width = width, .heigth = height } },
        .offset = .{ .left = left, .top = top },
        .color = .new(0.035, 0.04, 0.038, 0.82),
    });
    ui.add(null, .{
        .size = .{ .fixed = .{ .width = label_width, .heigth = height } },
        .offset = .{ .left = left + 14, .top = top },
        .child_anchor = .{ .x = .start, .y = .center },
        .text = .{ .data = label, .size = 20, .color = .new(0.9, 0.93, 0.86, 1) },
    });
    ui.add(null, .{
        .size = .{ .fixed = .{ .width = track_width, .heigth = track_height } },
        .offset = .{ .left = track_left, .top = track_top },
        .color = .new(0.09, 0.1, 0.095, 1),
    });
    ui.add(null, .{
        .size = .{ .fixed = .{ .width = track_width * normalized, .heigth = track_height } },
        .offset = .{ .left = track_left, .top = track_top },
        .color = .new(0.88, 0.55, 0.08, 0.96),
    });
    ui.add(null, .{
        .size = .{ .fixed = .{ .width = 10, .heigth = height - 10 } },
        .offset = .{ .left = track_left + track_width * normalized - 5, .top = top + 5 },
        .color = .new(0.94, 0.96, 0.9, 1),
    });
    ui.add(null, .{
        .size = .{ .fixed = .{ .width = value_width, .heigth = height - 8 } },
        .offset = .{ .left = left + width - value_width, .top = top + 4 },
        .color = .new(0.06, 0.065, 0.055, 0.96),
        .child_anchor = .{ .x = .center, .y = .center },
        .text = .{ .data = value_text, .size = 20, .color = .new(0.94, 0.96, 0.9, 1) },
    });
    ui.add(null, .{
        .name = name,
        .size = .{ .fixed = .{ .width = track_width, .heigth = height } },
        .offset = .{ .left = track_left, .top = top },
        .color = .new(0, 0, 0, 0),
    });

    if (!ui.isActive(name) and !ui.isDragging(name)) return null;
    const mouse_x = std.math.clamp(ui.mouse_state.position.left, track_left, track_left + track_width);
    const next = min + ((mouse_x - track_left) / track_width) * (max - min);
    return next;
}

fn addControllerDiagram(ui: *Ui, left: f32, top: f32, width: f32, height: f32) void {
    const body_left = left + width * 0.12;
    const body_top = top + 12;
    const body_width = width * 0.76;
    const body_height = height - 24;
    ui.add(null, .{
        .size = .{ .fixed = .{ .width = body_width, .heigth = body_height } },
        .offset = .{ .left = body_left, .top = body_top },
        .color = .new(0.035, 0.04, 0.038, 0.82),
    });
    addControllerButtonLabel(ui, "LT", "Aim", body_left + 30, body_top + 12, 82, 28);
    addControllerButtonLabel(ui, "LB", "Sprint", body_left + 122, body_top + 12, 82, 28);
    addControllerButtonLabel(ui, "RB", "Attack", body_left + body_width - 204, body_top + 12, 82, 28);
    addControllerButtonLabel(ui, "RT", "Attack", body_left + body_width - 112, body_top + 12, 82, 28);
    addControllerButtonLabel(ui, "L Stick", "Move", body_left + 58, body_top + 70, 92, 40);
    addControllerButtonLabel(ui, "D-Pad", "Items", body_left + 170, body_top + 82, 82, 36);
    addControllerButtonLabel(ui, "Select", "Map", body_left + body_width * 0.5 - 92, body_top + 72, 72, 30);
    addControllerButtonLabel(ui, "Start", "Pause", body_left + body_width * 0.5 + 20, body_top + 72, 72, 30);
    addControllerButtonLabel(ui, "R Stick", "Camera", body_left + body_width - 152, body_top + 70, 92, 40);
    addControllerButtonLabel(ui, "Y", "Reload", body_left + body_width - 118, body_top + 52, 34, 28);
    addControllerButtonLabel(ui, "X", "Interact", body_left + body_width - 154, body_top + 84, 34, 28);
    addControllerButtonLabel(ui, "B", "Cancel", body_left + body_width - 82, body_top + 84, 34, 28);
    addControllerButtonLabel(ui, "A", "Jump", body_left + body_width - 118, body_top + 116, 34, 28);
}

fn addControllerButtonLabel(ui: *Ui, button: []const u8, mapping: []const u8, left: f32, top: f32, width: f32, height: f32) void {
    ui.add(null, .{
        .size = .{ .fixed = .{ .width = width, .heigth = height } },
        .offset = .{ .left = left, .top = top },
        .color = .new(0.08, 0.085, 0.08, 1),
        .child_anchor = .{ .x = .center, .y = .center },
        .text = .{ .data = button, .size = 16, .color = .new(0.94, 0.96, 0.9, 1) },
    });
    ui.add(null, .{
        .size = .{ .fixed = .{ .width = width + 18, .heigth = 20 } },
        .offset = .{ .left = left - 9, .top = top + height + 2 },
        .child_anchor = .{ .x = .center, .y = .center },
        .text = .{ .data = mapping, .size = 13, .color = .new(0.68, 0.72, 0.66, 1) },
    });
}

fn bindingRowName(action: Controller.Action) []const u8 {
    return switch (action) {
        .move_forward => "bind_move_forward",
        .move_backward => "bind_move_backward",
        .move_left => "bind_move_left",
        .move_right => "bind_move_right",
        .jump => "bind_jump",
        .sprint => "bind_sprint",
        .reload => "bind_reload",
        .interact => "bind_interact",
        .attack => "bind_attack",
        .aim => "bind_aim",
        .free_camera => "bind_free_camera",
    };
}

fn optionsTabName(tab: system.World.OptionsTab) []const u8 {
    return switch (tab) {
        .gameplay => "options_tab_gameplay",
        .keyboard_mouse => "options_tab_keyboard_mouse",
        .controller => "options_tab_controller",
        .audio => "options_tab_audio",
        .video => "options_tab_video",
        .graphics => "options_tab_graphics",
    };
}

fn optionsTabLabel(tab: system.World.OptionsTab) []const u8 {
    return switch (tab) {
        .gameplay => "Gameplay",
        .keyboard_mouse => "Keyboard-Mouse",
        .controller => "Controller",
        .audio => "Audio",
        .video => "Video",
        .graphics => "Graphics",
    };
}

fn boolText(value: bool) []const u8 {
    return if (value) "On" else "Off";
}

fn addPauseButton(ui: *Ui, name: []const u8, text: []const u8, width: f32, height: f32) void {
    const hot = ui.isHot(name);
    ui.add("pause_panel", .{
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

fn addOptionsButton(ui: *Ui, name: []const u8, text: []const u8, left: f32, top: f32, width: f32, height: f32) void {
    const hot = ui.isHot(name);
    ui.add(null, .{
        .name = name,
        .size = .{ .fixed = .{ .width = width, .heigth = height } },
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

fn inGame(info: *const Info, ui: *Ui) !void {
    if (info.world.getPtr(info.world.player_id)) |player| {
        const health = player.stats.get(.health);
        const healthbar_width: f32 = 200 * health.current / health.max;
        const healthbar_heigth: f32 = 50;
        ui.add(null, .{
            .name = "health",
            .offset = .{
                .top = ui.screen_heigth - healthbar_heigth - 10,
                .left = 10,
            },
            .child_anchor = .{ .x = .center, .y = .center },
            .size = .{ .fixed = .{ .heigth = healthbar_heigth, .width = healthbar_width } },
            .color = .new(0, 1, 0, 1),
            .text = .{ .data = ui.print("{d} / {d}", .{ health.current, health.max }), .size = 40 },
        });

        const inventory_width: f32 = ui.screen_width * 0.8;
        const inventory_heigth: f32 = 60;
        ui.add(null, .{
            .name = "HUD",
            .axis_align = .verical,
            .offset = .{ .top = 60, .left = ui.screen_width / 2 - inventory_width / 2 },
            // .child_anchor = .{ .x = .end, .y = .end },
            .size = .{ .percent = .{ .heigth = 1, .width = 1 } },
        });

        ui.add("HUD", .{
            .name = "inventory",
            // .child_anchor = .{ .y = .end, .x = .end },
            .size = .{ .fixed = .{ .width = inventory_width, .heigth = inventory_heigth } },
            .color = .new(0.5, 0.5, 0.5, 0.4),
            .axis_align = .horizontal,
            .gap = 10,
        });
        for (std.enums.values(shared.Item.Kind)) |item_kind| {
            const amount = player.inventory.get(item_kind);
            if (amount == 0) continue;
            const amount_text = ui.print("{d}", .{amount});
            ui.add("inventory", .{
                .size = .{ .fixed = .{
                    .heigth = inventory_heigth,
                    .width = inventory_heigth,
                } },

                .color = .new(1, 1, 1, 1),
                .name = ui.print("{t}", .{item_kind}),
                .texture = switch (item_kind) {
                    .health => .oxygen_tank,
                    .speed => .energy_drink,
                    .damage => .damage_item,
                    .attack_speed => .pickaxe,
                },
                .child_anchor = .{ .x = .end, .y = .end },
                .children = &.{.{
                    .size = .{ .fixed = ui.textSize(amount_text, 32) },
                    .text = .{
                        .data = amount_text,
                        .color = .new(0, 0, 0, 1),
                    },
                }},
            });
        }
        ui.add(
            "HUD",
            .{
                .size = .{ .fixed = .{ .heigth = inventory_heigth, .width = inventory_width } },
                .name = "info",
            },
        );
        ui.add("info", .{
            .size = .{ .percent = .{ .heigth = 1, .width = 0.5 } },
            .text = .{ .data = ui.print("Stage: {d}", .{info.world.stage}) },
        });

        for (std.enums.values(shared.Item.Kind)) |item_kind| {
            const amount = player.inventory.get(item_kind);
            if (amount == 0) continue;
            if (ui.isHot(ui.print("{t}", .{item_kind}))) {
                const attributes = item_kind.getAttributeValues();
                var tool_tip_text: []const u8 = "";
                inline for (std.meta.fields(shared.Item.Attribute)) |field| {
                    const value = @field(attributes, field.name);
                    if (value != 0) {
                        tool_tip_text = ui.print("{s}{s}: {d}", .{ tool_tip_text, field.name, value });
                    }
                }
                ui.add(
                    null,
                    .{
                        .offset = .{ .left = ui.mouse_state.position.left, .top = ui.mouse_state.position.top },
                        .size = .{ .fixed = ui.textSize(tool_tip_text, 32) },
                        .text = .{ .data = ui.print("{s}", .{tool_tip_text}) },
                    },
                );
            }
        }
        if (info.world.options.show_crosshair) {
            ui.add(null, .{
                .name = "crosshair",
                .size = .{
                    .fixed = .{ .heigth = 0, .width = 0 },
                },
                .offset = .{ .left = ui.screen_width / 2, .top = ui.screen_heigth / 2 },
                .child_anchor = .{ .x = .center, .y = .center },
                .children = &.{
                    .{
                        .size = .{
                            .fixed = .{
                                .heigth = 50,
                                .width = 50,
                            },
                        },
                        .color = .new(1, 1, 1, 1),
                        .texture = .crosshair,
                    },
                },
            });
        }
        if (info.world.options.show_hud_stats) {
            const stats_box_width: u32 = 200;
            const stats_box_heigth: u32 = 200;
            ui.add(null, .{
                .name = "stats",
                .offset = .{ .top = ui.screen_heigth - stats_box_heigth, .left = ui.screen_width - stats_box_width },
                .size = .{ .fixed = .{ .width = stats_box_width, .heigth = stats_box_heigth } },
                .color = .new(0.5, 0.5, 0.5, 0.7),
                .axis_align = .verical,
                // .child_anchor = .{ .x = .end, .y = .start },
                .gap = 10,
            });
            for (std.enums.values(shared.Stat.Kind)) |stat_kind| {
                const stat = player.stats.get(stat_kind);
                ui.add("stats", .{
                    .text = .{ .data = ui.print("{t} : {d:.2}", .{ stat_kind, stat.current }) },
                    .color = .grey,
                    .size = .{ .percent = .{
                        .heigth = 0.2,
                        .width = 1,
                    } },
                });
            }
        }

        const portal = info.world.getPtr(info.world.teleporter_id);
        const teleporter_active = if (portal) |entity| entity.teleporter.active else false;
        if (teleporter_active == false) {
            if (portal) |entity| {
                if (nz.vec.length(player.transform.position - entity.transform.position) < shared.teleporter.intertact_distance) {
                    ui.add(
                        null,
                        .{
                            .name = "active_teleport",
                            .size = .{ .fixed = .{ .heigth = 0, .width = 0 } },
                            .text = .{ .data = "E" },
                            .offset = .{ .left = ui.screen_width / 2, .top = ui.screen_heigth / 2 },
                        },
                    );
                }
            }
        } else {
            var total_boss_health: f32 = 0;
            var total_boss_max_health: f32 = 0;
            for (info.world.teleporter_bosses.items) |boss_id| {
                const boss = info.world.getPtr(boss_id) orelse continue;
                const boss_health = boss.stats.get(.health);
                total_boss_health += boss_health.current;
                total_boss_max_health += boss_health.max;
            }
            const boss_healthbar_width: f32 = (ui.screen_width * 0.9) * (total_boss_health / total_boss_max_health);
            const boss_healthbar_heigth: f32 = 30;
            ui.add(null, .{
                .offset = .{
                    .top = 20,
                    .left = ui.screen_width / 2 - boss_healthbar_width / 2,
                },
                .size = .{ .fixed = .{ .heigth = boss_healthbar_heigth, .width = boss_healthbar_width } },
                .color = .new(1, 0, 0, 1),
            });
            if (portal) |entity| {
                const teleporter = entity.teleporter;
                if (teleporter.charged == teleporter.max_charge and info.world.teleporter_bosses.items.len == 0) {
                    if (nz.vec.length(player.transform.position - entity.transform.position) < shared.teleporter.intertact_distance) {
                        ui.add(
                            null,
                            .{
                                .name = "active_teleport",
                                .size = .{ .fixed = .{ .heigth = 0, .width = 0 } },
                                .text = .{ .data = "E" },
                                .offset = .{ .left = ui.screen_width / 2, .top = ui.screen_heigth / 2 },
                            },
                        );
                    }
                } else {
                    ui.add(
                        "info",
                        .{
                            .size = .{ .percent = .{ .heigth = 1, .width = 0.5 } },
                            .text = .{ .data = ui.print("Teleport Charge: {d:.2}", .{teleporter.charged}) },
                        },
                    );
                }
            }
        }
    }
}
