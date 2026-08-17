const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const Ui = @import("ui");
const NetworkManager = @import("../NetworkManager.zig");
const Options = @import("../../Options.zig");
const Hud = @import("../Hud.zig");
const Request = Hud.Request;

const hot_seconds: f32 = 0.08;

pub fn update(network_manager: *NetworkManager, ui: *Ui, hud: *Hud, options: *Options) !Request {
    const button_width = std.math.clamp(ui.screen_width * 0.155, @as(f32, 216), @as(f32, 320));
    const button_height = std.math.clamp(ui.screen_height * 0.048, @as(f32, 36), @as(f32, 46));
    const button_gap = std.math.clamp(ui.screen_height * 0.012, @as(f32, 7), @as(f32, 11));
    const button_text_size = std.math.clamp(button_height * 0.55, @as(f32, 20), @as(f32, 25));
    const left = std.math.clamp(ui.screen_width * 0.07, @as(f32, 48), @as(f32, 132));
    const total_height = button_height * 5 + button_gap * 4;
    const max_top = @max(@as(f32, 28), ui.screen_height - total_height - 28);
    const top = std.math.clamp((ui.screen_height - total_height) * 0.5, @as(f32, 28), max_top);
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
    addDevPlanetButton(ui, options.dev_planet, left, top + (button_height + button_gap) * 4, button_width, button_height, button_text_size);

    if (ui.isClicked("menu_dev_planet")) {
        options.dev_planet = !options.dev_planet;
    }

    if (ui.isClicked("menu_singleplayer")) {
        hud.screen = .main;
        network_manager.requestHost(.singleplayer, options.dev_planet);
    }
    if (steam_logged_on and ui.isClicked("menu_multiplayer")) {
        hud.screen = .multiplayer;
        if (!network_manager.server_list.refresh and network_manager.server_list.count == 0) {
            network_manager.server_list.refresh = true;
        }
    } else if (!steam_logged_on and ui.isClicked("menu_multiplayer")) {
        hud.screen = .multiplayer;
    }
    if (ui.isClicked("menu_settings")) {
        hud.screen = .main;
        hud.overlay = .{ .options = .{ .return_to_pause = false } };
    }
    if (ui.isClicked("menu_quit")) {
        return .quit;
    }

    ui.add(null, .{
        .name = "menu_version",
        .size = .{ .fixed = .{ .height = 22, .width = 140 } },
        .offset = .{ .left = 10, .top = ui.screen_height - 28 },
        .color = .new(0, 0, 0, 0),
        .child_anchor = .{ .x = .start, .y = .center },
        .text = .{ .data = "v" ++ shared.version, .size = 18, .color = .new(0.55, 0.58, 0.54, 1) },
    });

    switch (hud.screen) {
        .main => {},
        .multiplayer => try multiplayerPanel(network_manager, ui, options, panel_left, panel_top, panel_width),
    }
    return .none;
}

fn addDevPlanetButton(ui: *Ui, dev_mode: bool, left: f32, top: f32, width: f32, height: f32, text_size: f32) void {
    const hot = ui.isHot("menu_dev_planet");
    const bg = if (dev_mode)
        nz.color.Rgba(f32).new(0.16, if (hot) 0.72 else 0.58, 0.2, 1)
    else
        nz.color.Rgba(f32).new(if (hot) 0.78 else 0.62, 0.16, 0.16, 1);

    ui.add(null, .{
        .name = "menu_dev_planet",
        .size = .{ .fixed = .{ .height = height, .width = width } },
        .offset = .{ .left = left, .top = top },
        .color = bg,
        .child_anchor = .{ .x = .center, .y = .center },
        .text = .{
            .data = if (dev_mode) "Dev Planet: ON" else "Dev Planet: OFF",
            .size = text_size,
            .color = nz.color.Rgba(f32).new(0.94, 0.96, 0.9, 1),
        },
    });
}

fn addMainMenuButton(ui: *Ui, name: []const u8, text: []const u8, left: f32, top: f32, width: f32, height: f32, text_size: f32, selected: bool, enabled: bool) void {
    const hot = enabled and (selected or ui.isHot(name));
    const hot_time = ui.animate(name, if (hot) 1 else 0, hot_seconds);
    const bg = if (!enabled)
        nz.color.Rgba(f32).new(0.045, 0.048, 0.045, 1)
    else
        nz.color.Rgba(f32).new(
            std.math.lerp(0.02, 0.88, hot_time),
            std.math.lerp(0.025, 0.55, hot_time),
            std.math.lerp(0.025, 0.08, hot_time),
            1,
        );
    const fg = if (!enabled)
        nz.color.Rgba(f32).new(0.44, 0.46, 0.42, 1)
    else
        nz.color.Rgba(f32).new(
            std.math.lerp(0.94, 0.02, hot_time),
            std.math.lerp(0.96, 0.02, hot_time),
            std.math.lerp(0.9, 0.015, hot_time),
            1,
        );

    ui.add(null, .{
        .name = name,
        .size = .{ .fixed = .{ .height = height, .width = width } },
        .offset = .{ .left = left, .top = top },
        .color = bg,
        .child_anchor = .{ .x = .center, .y = .center },
        .text = .{ .data = text, .size = text_size, .color = fg },
    });
}

pub fn multiplayerPanel(network_manager: *NetworkManager, ui: *Ui, options: *Options, left: f32, top: f32, width: f32) !void {
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
        .size = .{ .fixed = .{ .height = button_height, .width = button_width } },
        .offset = .{ .left = left, .top = top },
        .color = if (!steam_logged_on) .new(0.045, 0.048, 0.045, 0.82) else if (ui.isHot("menu_refresh")) .new(0.14, 0.14, 0.12, 0.92) else .new(0.02, 0.025, 0.025, 0.82),
        .child_anchor = .{ .x = .center, .y = .center },
        .text = .{ .data = "Refresh Servers", .size = 26, .color = if (steam_logged_on) .new(0.94, 0.96, 0.9, 1) else .new(0.44, 0.46, 0.42, 1) },
    });
    if (steam_logged_on and ui.isClicked("menu_refresh") and network_manager.server_list.refresh == false) {
        network_manager.server_list.refresh = true;
    }
    ui.add(null, .{
        .name = "menu_host",
        .size = .{ .fixed = .{ .height = button_height, .width = button_width } },
        .offset = .{ .left = left + button_width + row_gap, .top = top },
        .color = if (!steam_logged_on) .new(0.045, 0.048, 0.045, 0.82) else if (hosting or ui.isHot("menu_host")) .new(0.88, 0.55, 0.08, 0.96) else .new(0.02, 0.025, 0.025, 0.82),
        .child_anchor = .{ .x = .center, .y = .center },
        .text = .{
            .data = if (!steam_logged_on) "Steam Offline" else if (hosting) "Hosting..." else if (host_failed) "Host Failed" else "Host",
            .size = 26,
            .color = if (!steam_logged_on) .new(0.44, 0.46, 0.42, 1) else if (hosting or ui.isHot("menu_host")) .new(0.02, 0.02, 0.015, 1) else .new(0.94, 0.96, 0.9, 1),
        },
    });
    if (ui.isClicked("menu_host") and (network_manager.host_state == .none or network_manager.host_state == .failed or network_manager.host_state == .steam_offline)) {
        network_manager.requestHost(.multiplayer, options.dev_planet);
    }

    if (network_manager.server_list.count == 0) {
        ui.add(null, .{
            .size = .{ .fixed = .{ .height = button_height, .width = panel_width } },
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
            .size = .{ .fixed = .{ .height = row_height, .width = panel_width } },
            .offset = .{ .left = left, .top = row_top },
            .color = if (bad_version) .new(0.5, 0.09, 0.07, 0.92) else if (hot) .new(0.88, 0.55, 0.08, 0.96) else .new(0.02, 0.025, 0.025, 0.82),
            .children = &.{
                .{
                    .size = .{ .fixed = .{ .height = 24, .width = panel_width } },
                    .offset = .{ .left = 12, .top = 0 },
                    .text = .{ .data = title, .size = 20, .color = if (hot) .new(0.02, 0.02, 0.015, 1) else .new(0.94, 0.96, 0.9, 1) },
                },
                .{
                    .size = .{ .fixed = .{ .height = 16, .width = panel_width } },
                    .offset = .{ .left = 12, .top = 0 },
                    .text = .{ .data = host_text, .size = 14, .color = if (hot) .new(0.06, 0.055, 0.035, 1) else .new(0.68, 0.72, 0.66, 1) },
                },
                .{
                    .size = .{ .fixed = .{ .height = 16, .width = panel_width } },
                    .offset = .{ .left = 12, .top = 0 },
                    .text = .{ .data = player_text, .size = 14, .color = if (hot) .new(0.06, 0.055, 0.035, 1) else .new(0.68, 0.72, 0.66, 1) },
                },
            },
        });
        if (ui.isClicked(id) and !bad_version and network_manager.steam_client.server_conn == 0) {
            try network_manager.steam_client.connectToServer(server.steam_id);
            std.log.info("connect to {d}", .{server.steam_id});
        }
    }
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
