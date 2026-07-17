const Hud = @This();

const std = @import("std");
const nz = @import("shared").numz;
const shared = @import("shared");
const system = @import("../system.zig");
const tracy = @import("ztracy");
const Info = system.Info;
const Ui = @import("../Renderer/Vulkan/Ui.zig");
const NetworkManager = @import("NetworkManager.zig");
const Controller = @import("Controller.zig");
const Options = @import("../Options.zig");

pub const Screen = enum {
    main,
    multiplayer,
};

pub const OptionsTab = enum {
    gameplay,
    keyboard_mouse,
    video,
    graphics,
};

pub const Overlay = union(enum) {
    none,
    pause,
    options: struct { return_to_pause: bool },
};

pub const Request = union(enum) {
    none,
    main_menu,
    quit,
};

screen: Screen = .main,
overlay: Overlay = .none,
options_tab: OptionsTab = .gameplay,

pub fn update(
    hud: *Hud,
    info: *const Info,
    scene: system.Scene,
    network_manager: *NetworkManager,
    ui: *Ui,
    controller: *Controller,
    options: *Options,
) !Request {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();

    const position: [2]f32 = .{ @floatCast(controller.mouse_pos[0]), @floatCast(controller.mouse_pos[1]) };
    ui.start(.{
        .position = .{ .left = position[0], .top = position[1] },
        .left_click = controller.mouse_button_left,
        .right_click = controller.mouse_button_right,
    });
    var request: Request = .none;
    if (scene == .menu) {
        request = try mainMenu(network_manager, ui, hud);
        if (hud.overlay == .options) optionsMenu(ui, hud, options, controller);
    } else {
        try inGame(info, network_manager, ui, options);
        switch (hud.overlay) {
            .none => {},
            .pause => request = try pauseMenu(ui, hud),
            .options => optionsMenu(ui, hud, options, controller),
        }
    }

    ui.end();
    return request;
}

fn mainMenu(network_manager: *NetworkManager, ui: *Ui, hud: *Hud) !Request {
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
    addMainMenuButton(ui, "menu_multiplayer", "Multiplayer", left, top + (button_height + button_gap), button_width, button_height, button_text_size, hud.screen == .multiplayer, steam_logged_on);
    addMainMenuButton(ui, "menu_settings", "Options", left, top + (button_height + button_gap) * 2, button_width, button_height, button_text_size, hud.overlay == .options, true);
    addMainMenuButton(ui, "menu_quit", "Quit to Desktop", left, top + (button_height + button_gap) * 3, button_width, button_height, button_text_size, false, true);

    if (ui.isActive("menu_singleplayer")) {
        hud.screen = .main;
        network_manager.requestHost(.singleplayer);
    }
    if (steam_logged_on and ui.isActive("menu_multiplayer")) {
        hud.screen = .multiplayer;
        if (!network_manager.server_list.refresh and network_manager.server_list.count == 0) {
            network_manager.server_list.refresh = true;
        }
    } else if (!steam_logged_on and ui.isActive("menu_multiplayer")) {
        hud.screen = .multiplayer;
    }
    if (ui.isActive("menu_settings")) {
        hud.screen = .main;
        hud.overlay = .{ .options = .{ .return_to_pause = false } };
    }
    if (ui.isActive("menu_quit")) {
        return .quit;
    }

    switch (hud.screen) {
        .main => {},
        .multiplayer => try multiplayerPanel(network_manager, ui, panel_left, panel_top, panel_width),
    }
    return .none;
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
    const button_height: f32 = 42;
    const row_height: f32 = 64;
    const row_gap: f32 = 8;
    const panel_width = @max(@as(f32, 260), width);
    const button_width = (panel_width - row_gap) * 0.5;
    const hosting = network_manager.host_state == .requested or network_manager.host_state == .waiting or network_manager.host_state == .hosting;
    const host_failed = network_manager.host_state == .failed;
    const steam_logged_on = network_manager.steam_logged_on;

    ui.add(null, .{
        .name = "menu_refresh",
        .size = .{ .fixed = .{ .heigth = button_height, .width = button_width } },
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
        .size = .{ .fixed = .{ .heigth = button_height, .width = button_width } },
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
            .size = .{ .fixed = .{ .heigth = button_height, .width = panel_width } },
            .offset = .{ .left = left, .top = top + button_height + row_gap },
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
        const id = serverId(ui, server);
        const tags = serverTags(server);
        const host = tagValue(tags, "host");
        const players = tagValue(tags, "players");
        const server_version_text = tagValue(tags, "ver");
        const bad_version = server_version_text.len != 0 and (std.fmt.parseInt(u32, server_version_text, 10) catch 0) != shared.net.protocol_version;
        const title = if (bad_version)
            ui.print("BAD VERSION - {s}", .{clippedText(ui, serverTitle(ui, server), 28)})
        else
            clippedText(ui, serverTitle(ui, server), 42);
        const host_text = if (host.len == 0)
            "Host: unknown"
        else
            ui.print("Host: {s}", .{clippedText(ui, host, 36)});
        const player_text = if (bad_version)
            "Incompatible version"
        else if (players.len == 0)
            ui.print("Players: {d}/{d}", .{ @max(server.player_count, 0), @max(server.max_players, 0) })
        else
            ui.print("Players: {s}", .{clippedText(ui, players, 54)});
        const row_top = top + button_height + row_gap + (row_height + row_gap) * @as(f32, @floatFromInt(i));
        const hot = ui.isHot(id);

        ui.add(null, .{
            .name = id,
            .axis_align = .vertical,
            .gap = 2,
            .child_anchor = .{ .x = .start, .y = .center },
            .size = .{ .fixed = .{ .heigth = row_height, .width = panel_width } },
            .offset = .{ .left = left, .top = row_top },
            .color = if (bad_version) .new(0.5, 0.09, 0.07, 0.92) else if (hot) .new(0.88, 0.55, 0.08, 0.96) else .new(0.02, 0.025, 0.025, 0.82),
            .children = &.{
                .{
                    .size = .{ .fixed = .{ .heigth = 24, .width = panel_width } },
                    .offset = .{ .left = 12, .top = 0 },
                    .text = .{ .data = title, .size = 20, .color = if (hot) .new(0.02, 0.02, 0.015, 1) else .new(0.94, 0.96, 0.9, 1) },
                },
                .{
                    .size = .{ .fixed = .{ .heigth = 16, .width = panel_width } },
                    .offset = .{ .left = 12, .top = 0 },
                    .text = .{ .data = host_text, .size = 14, .color = if (hot) .new(0.06, 0.055, 0.035, 1) else .new(0.68, 0.72, 0.66, 1) },
                },
                .{
                    .size = .{ .fixed = .{ .heigth = 16, .width = panel_width } },
                    .offset = .{ .left = 12, .top = 0 },
                    .text = .{ .data = player_text, .size = 14, .color = if (hot) .new(0.06, 0.055, 0.035, 1) else .new(0.68, 0.72, 0.66, 1) },
                },
            },
        });
        if (ui.isActive(id) and !bad_version) {
            try network_manager.steam_client.connectToServer(server.steam_id);
            std.log.debug("connect to {d}", .{server.steam_id});
        }
    }
}

fn pauseMenu(ui: *Ui, hud: *Hud) !Request {
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
        .axis_align = .vertical,
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
        hud.overlay = .none;
    }
    if (ui.isActive("pause_options")) {
        hud.overlay = .{ .options = .{ .return_to_pause = true } };
    }
    if (ui.isActive("pause_main_menu")) {
        return .main_menu;
    }
    return .none;
}

fn optionsMenu(ui: *Ui, hud: *Hud, options: *Options, controller: *Controller) void {
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
    const tabs = [_]OptionsTab{ .gameplay, .keyboard_mouse, .video, .graphics };
    const tab_width = (content_width - tab_gap * @as(f32, @floatFromInt(tabs.len - 1))) / @as(f32, @floatFromInt(tabs.len));
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
    const row_gap: f32 = 10;
    if (addOptionToggle(ui, "options_hud_stats", "HUD Stats", boolText(options.show_hud_stats), left, top, width, row_height)) {
        options.show_hud_stats = !options.show_hud_stats;
    }
    if (addOptionToggle(ui, "options_crosshair", "Crosshair", boolText(options.show_crosshair), left, top + (row_height + row_gap), width, row_height)) {
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
    for (Controller.bindable_actions, 0..) |action, i| {
        const column: f32 = if (i < 6) 0 else 1;
        const row: f32 = @floatFromInt(if (i < 6) i else i - 6);
        const row_left = left + column * (column_width + column_gap);
        const row_top = bindings_top + row * (binding_height + binding_gap);
        if (addBindingRow(ui, controller, action, row_left, row_top, column_width, binding_height)) {
            controller.rebinding_action = action;
            controller.clearInput();
        }
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

fn bindingRowName(action: Controller.Action) []const u8 {
    return switch (action) {
        .move_forward => "bind_move_forward",
        .move_backward => "bind_move_backward",
        .move_left => "bind_move_left",
        .move_right => "bind_move_right",
        .jump => "bind_jump",
        .move_down => "bind_move_down",
        .reload => "bind_reload",
        .interact => "bind_interact",
        .attack => "bind_attack",
        .aim => "bind_aim",
        .free_camera => "bind_free_camera",
        .debug_colliders => "bind_debug_colliders",
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

fn serverId(ui: *Ui, server: *const shared.SteamNet.Client.ServerInfo) []const u8 {
    const id = std.mem.sliceTo(server.id_str[0..], 0);
    return if (id.len == 0) ui.print("{d}", .{server.steam_id}) else id;
}

fn serverTitle(ui: *Ui, server: *const shared.SteamNet.Client.ServerInfo) []const u8 {
    const title = std.mem.sliceTo(server.name[0..], 0);
    return if (title.len == 0) serverId(ui, server) else title;
}

fn serverTags(server: *const shared.SteamNet.Client.ServerInfo) []const u8 {
    return std.mem.sliceTo(server.game_tags[0..], 0);
}

fn tagValue(tags: []const u8, comptime key: []const u8) []const u8 {
    var rest = tags;
    while (rest.len != 0) {
        const separator_index = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
        const part = rest[0..separator_index];
        if (part.len > key.len and std.mem.eql(u8, part[0..key.len], key) and part[key.len] == '=') {
            return part[key.len + 1 ..];
        }
        if (separator_index == rest.len) break;
        rest = rest[separator_index + 1 ..];
    }
    return "";
}

fn clippedText(ui: *Ui, text: []const u8, max_len: usize) []const u8 {
    if (text.len <= max_len) return text;
    if (max_len <= 3) return text[0..max_len];
    return ui.print("{s}...", .{text[0 .. max_len - 3]});
}

fn inGame(info: *const Info, network_manager: *NetworkManager, ui: *Ui, options: *Options) !void {
    const ping = network_manager.ping_milliseconds;
    const ping_text = if (ping < 0) "-- ms" else ui.print("{d} ms", .{ping});
    const ping_color: nz.color.Rgba(f32) = if (ping < 0)
        .new(0.68, 0.72, 0.66, 1)
    else if (ping < 60)
        .new(0.25, 0.85, 0.3, 1)
    else if (ping < 120)
        .new(0.9, 0.78, 0.12, 1)
    else
        .new(0.9, 0.2, 0.15, 1);
    const ping_size = ui.textSize(ping_text, 24);
    ui.add(null, .{
        .size = .{ .fixed = ping_size },
        .offset = .{ .left = ui.screen_width - ping_size.width - 12, .top = 10 },
        .text = .{ .data = ping_text, .size = 24, .color = ping_color },
    });

    if (info.world.getPtr(info.world.player_id)) |player| {
        addNameTags(info, ui);

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

        const inventory_width: f32 = ui.screen_width * 0.6;
        const inventory_heigth: f32 = 60;
        ui.add(null, .{
            .name = "HUD",
            .axis_align = .horizontal,
            .offset = .{ .top = 60, .left = 0 },
            // .child_anchor = .{ .x = .end, .y = .end },
            .size = .{ .percent = .{ .heigth = 1, .width = 1 } },
        });

        ui.add("HUD", .{
            .size = .{ .percent = .{ .heigth = 1, .width = 0.2 } },
            .text = .{ .data = ui.print("$: {d}", .{player.currency}) },
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
                    .rocket => .rocket_item,
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
        ui.add(
            "HUD",
            .{
                .size = .{ .percent = .{ .heigth = 1, .width = 0.2 } },
                .text = .{ .data = ui.print("stage: {d}", .{info.world.stage}) },
            },
        );

        if (options.show_crosshair) {
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
        if (options.show_hud_stats) {
            const stats_box_width: u32 = 200;
            const stats_box_heigth: u32 = 200;
            ui.add(null, .{
                .name = "stats",
                .offset = .{ .top = ui.screen_heigth - stats_box_heigth, .left = ui.screen_width - stats_box_width },
                .size = .{ .fixed = .{ .width = stats_box_width, .heigth = stats_box_heigth } },
                .color = .new(0.5, 0.5, 0.5, 0.7),
                .axis_align = .vertical,
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

fn addNameTags(info: *const Info, ui: *Ui) void {
    const label_size: f32 = 18;
    const padding_x: f32 = 8;
    const padding_y: f32 = 3;

    for (info.world.entities.values()) |*entity| {
        if (entity.kind != .player) continue;

        const name = if (entity.player_name.len != 0)
            entity.player_name
        else
            ui.print("{s} {d}", .{ shared.default_player_name, @intFromEnum(entity.id) });

        const up: nz.Vec3(f32) = if (nz.vec.length(entity.transform.position) > 0.001)
            nz.vec.normalize(entity.transform.position)
        else
            entity.transform.rotation.rotateVec(.{ 0, 1, 0 });
        const tag_position = entity.transform.position + nz.vec.scale(up, 1.6);
        if (info.world.planet_radius > 0 and isOccludedByPlanet(info.world.camera.transform.position, tag_position, info.world.planet_radius)) continue;
        const screen = worldToScreen(info.world.camera, tag_position, ui.screen_width, ui.screen_heigth) orelse continue;
        const text_size = ui.textSize(name, label_size);
        const tag_width = text_size.width + padding_x * 2;
        const tag_heigth = text_size.heigth + padding_y * 2;

        ui.add(null, .{
            .offset = .{
                .left = screen[0] - tag_width / 2,
                .top = screen[1] - tag_heigth - 4,
            },
            .size = .{ .fixed = .{
                .width = tag_width,
                .heigth = tag_heigth,
            } },
            .color = .new(0, 0, 0, 0.45),
            .child_anchor = .{ .x = .center, .y = .center },
            .children = &.{.{
                .size = .{ .fixed = text_size },
                .text = .{
                    .data = name,
                    .size = label_size,
                    .color = .new(1, 1, 1, 0.95),
                },
            }},
        });
    }
}

fn worldToScreen(camera: system.Camera, world_position: nz.Vec3(f32), width: f32, heigth: f32) ?[2]f32 {
    if (width <= 0 or heigth <= 0) return null;

    const aspect = width / heigth;
    const clip = camera.viewProj(aspect).mulVec4(.{ world_position[0], world_position[1], world_position[2], 1 });
    if (clip[3] <= 0.001) return null;

    const ndc = clip / @as(nz.Vec4(f32), @splat(clip[3]));
    if (ndc[0] < -1 or ndc[0] > 1 or ndc[1] < -1 or ndc[1] > 1 or ndc[2] < 0 or ndc[2] > 1) return null;
    return .{
        (ndc[0] * 0.5 + 0.5) * width,
        (ndc[1] * 0.5 + 0.5) * heigth,
    };
}

fn isOccludedByPlanet(camera_position: nz.Vec3(f32), tag_position: nz.Vec3(f32), planet_radius: f32) bool {
    const segment = tag_position - camera_position;
    const segment_len_sq = nz.vec.dot(segment, segment);
    if (segment_len_sq <= 0.0001) return false;
    const t = std.math.clamp(-nz.vec.dot(camera_position, segment) / segment_len_sq, 0, 1);
    const closest = camera_position + nz.vec.scale(segment, t);
    return nz.vec.length(closest) < planet_radius + 0.2;
}
