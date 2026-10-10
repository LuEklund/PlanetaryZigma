const std = @import("std");
const shared = @import("shared");
const dvui = @import("dvui");
const Network = @import("../Network.zig");
const Options = @import("../../Options.zig");
const Hud = @import("../Hud.zig");
const style = @import("style.zig");
const Request = Hud.Request;

pub fn update(network: *Network, hud: *Hud, options: *Options) !Request {
    const area = style.screen();
    const button_width = std.math.clamp(area.w * 0.2, 260, 360);
    const button_height = std.math.clamp(area.h * 0.048, 36, 46);
    const left = std.math.clamp(area.w * 0.07, 48, 132);
    const column_height = (button_height + 16) * 6;
    const top = @max(28, (area.h - column_height) * 0.5);
    const steam_logged_on = network.steam_logged_on;
    const singleplayer_hosting = network.host_intent == .singleplayer and
        (network.host_state == .requested or network.host_state == .waiting or network.host_state == .hosting);
    const singleplayer_failed = network.host_intent == .singleplayer and network.host_state == .failed;
    const button_size: dvui.Size = .{ .w = button_width, .h = button_height };

    var request: Request = .none;
    {
        var column = dvui.box(
            @src(),
            .{ .dir = .vertical },
            .{ .rect = .{ .x = left, .y = top, .w = button_width, .h = area.h - top } },
        );
        defer column.deinit();
        if (style.button(
            @src(),
            if (singleplayer_hosting) "Starting..." else if (singleplayer_failed) "Start Failed" else "Singleplayer",
            0,
            button_size,
            singleplayer_hosting,
            true,
        )) {
            hud.screen = .main;
            network.requestHost(.singleplayer, options.dev_planet);
        }
        if (style.button(@src(), "Multiplayer", 0, button_size, hud.screen == .multiplayer, true)) {
            hud.screen = .multiplayer;
            if (steam_logged_on and !network.server_list.refresh and network.server_list.count == 0) {
                network.server_list.refresh = true;
            }
        }
        if (style.button(@src(), "Options", 0, button_size, hud.overlay == .options, true)) {
            hud.screen = .main;
            hud.overlay = .{ .options = .{ .return_to_pause = false } };
        }
        if (style.button(
            @src(),
            if (options.dev_planet) "Dev Planet: ON" else "Dev Planet: OFF",
            0,
            button_size,
            options.dev_planet,
            true,
        )) {
            options.dev_planet = !options.dev_planet;
        }
        if (style.button(@src(), "Zoo", 0, button_size, false, true)) request = .zoo;
        if (style.button(@src(), "Quit to Desktop", 0, button_size, false, true)) request = .quit;
    }

    dvui.labelNoFmt(@src(), "v" ++ shared.version, .{}, .{
        .rect = .{ .x = 10, .y = area.h - 28, .w = 160, .h = 22 },
        .font = style.font(18),
        .color_text = .fromColor(style.text_dim),
    });

    if (hud.screen == .multiplayer) {
        const panel_left = left + button_width + 32;
        try multiplayerPanel(
            network,
            options,
            panel_left,
            top,
            @max(280, area.w - panel_left - left),
        );
    }
    return request;
}

fn multiplayerPanel(network: *Network, options: *Options, left: f32, top: f32, width: f32) !void {
    const hosting = network.host_state == .requested or network.host_state == .waiting or network.host_state == .hosting;
    const host_failed = network.host_state == .failed;
    const steam_logged_on = network.steam_logged_on;

    var panel = dvui.box(@src(), .{ .dir = .vertical }, .{
        .rect = .{ .x = left, .y = top, .w = width, .h = style.screen().h - top - 40 },
        .background = true,
        .color_fill = .fromColor(style.panel),
        .padding = .all(10),
    });
    defer panel.deinit();
    {
        var row = dvui.box(
            @src(),
            .{ .dir = .horizontal, .equal_space = true },
            .{ .expand = .horizontal },
        );
        defer row.deinit();
        if (style.button(
            @src(),
            "Refresh Servers",
            0,
            .{ .w = 120, .h = 40 },
            false,
            steam_logged_on,
        ) and !network.server_list.refresh) {
            network.server_list.refresh = true;
        }
        const host_label = if (!steam_logged_on) "Steam Offline" else if (hosting) "Hosting..." else if (host_failed) "Host Failed" else "Host";
        if (style.button(
            @src(),
            host_label,
            0,
            .{ .w = 120, .h = 40 },
            hosting,
            steam_logged_on,
        ) and
            (network.host_state == .none or network.host_state == .failed or network.host_state == .steam_offline))
        {
            network.requestHost(.multiplayer, options.dev_planet);
        }
    }

    if (network.server_list.count == 0) {
        const status = if (!steam_logged_on) "Steam is offline" else if (hosting) "Hosting..." else if (network.server_list.refresh) "Searching for servers" else "No servers found";
        dvui.labelNoFmt(
            @src(),
            status,
            .{},
            .{
                .font = style.font(22),
                .color_text = .fromColor(style.text_dim),
                .gravity_x = 0.5,
                .padding = .all(12),
            },
        );
        return;
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();
    const max_rows = @min(network.server_list.count, network.server_list.servers.len);
    for (0..max_rows) |i| {
        const server = &network.server_list.servers[i];
        const tags = std.mem.sliceTo(server.game_tags[0..], 0);
        const host = tagValue(tags, "host");
        const players = tagValue(tags, "players");
        const server_version_text = tagValue(tags, "ver");
        const bad_version = server_version_text.len != 0 and (std.fmt.parseInt(
            u32,
            server_version_text,
            10,
        ) catch 0) != shared.net.protocol_version;
        const name = std.mem.sliceTo(server.name[0..], 0);

        var entry = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = i,
            .expand = .horizontal,
            .background = true,
            .color_fill = .fromColor(
                if (bad_version) style.rgba(.{ 0.5, 0.09, 0.07, 0.92 }) else style.control,
            ),
            .margin = .{ .y = 4, .h = 4 },
            .padding = .all(8),
        });
        defer entry.deinit();
        dvui.label(
            @src(),
            "{s}{s}",
            .{
                if (bad_version) "BAD VERSION - " else "",
                if (name.len == 0) "unnamed server" else name,
            },
            .{ .font = style.font(20), .color_text = .fromColor(style.text) },
        );
        dvui.label(
            @src(),
            "Host: {s}",
            .{if (host.len == 0) "unknown" else host},
            .{ .font = style.font(14), .color_text = .fromColor(style.text_dim) },
        );
        if (players.len == 0) {
            dvui.label(
                @src(),
                "Players: {d}/{d}",
                .{ @max(server.player_count, 0), @max(server.max_players, 0) },
                .{ .font = style.font(14), .color_text = .fromColor(style.text_dim) },
            );
        } else {
            dvui.label(
                @src(),
                "Players: {s}",
                .{players},
                .{ .font = style.font(14), .color_text = .fromColor(style.text_dim) },
            );
        }
        if (style.button(
            @src(),
            "Join",
            i,
            .{ .w = 80, .h = 32 },
            false,
            !bad_version,
        ) and network.steam_client.server_conn == 0) {
            try network.steam_client.connectToServer(server.steam_id);
            std.log.info("connect to {d}", .{server.steam_id});
        }
    }
}

fn tagValue(tags: []const u8, comptime key: []const u8) []const u8 {
    var rest = tags;
    while (rest.len != 0) {
        const separator_index = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
        const part = rest[0..separator_index];
        if (part.len > key.len and std.mem.eql(
            u8,
            part[0..key.len],
            key,
        ) and part[key.len] == '=') {
            return part[key.len + 1 ..];
        }
        if (separator_index == rest.len) break;
        rest = rest[separator_index + 1 ..];
    }
    return "";
}
