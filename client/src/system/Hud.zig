const std = @import("std");
const nz = @import("shared").numz;
const shared = @import("shared");
const system = @import("../system.zig");
const tracy = @import("ztracy");
const Info = system.Info;
const Ui = @import("../Renderer/Vulkan/Ui.zig");
const NetworkManager = @import("NetworkManager.zig");
const Controller = @import("Controller.zig");

pub fn update(self: *@This(), info: *const Info, network_manager: *NetworkManager, ui: *Ui, controller: *const Controller) !void {
    _ = self;
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();

    const position: [2]f32 = .{ @floatCast(controller.mouse_pos[0]), @floatCast(controller.mouse_pos[1]) };
    ui.start(.{
        .position = .{ .left = position[0], .top = position[1] },
        .left_click = controller.input_map.keys.mouse_button_left,
        .right_click = controller.input_map.keys.mouse_button_right,
    });
    if (network_manager.steam_client.server_conn == 0) {
        info.world.show_menu_scene = true;
        try mainMenu(info, network_manager, ui, controller);
    } else {
        info.world.show_menu_scene = false;
        try inGame(info, ui);
    }

    ui.end();
}

fn mainMenu(info: *const Info, network_manager: *NetworkManager, ui: *Ui, controller: *const Controller) !void {
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

    menuViewportManipulator(info, ui, controller);

    addMainMenuButton(ui, "menu_singleplayer", "Singleplayer", left, top, button_width, button_height, button_text_size, false);
    addMainMenuButton(ui, "menu_multiplayer", "Multiplayer", left, top + (button_height + button_gap), button_width, button_height, button_text_size, info.world.menu_screen == .multiplayer);
    addMainMenuButton(ui, "menu_settings", "Settings", left, top + (button_height + button_gap) * 2, button_width, button_height, button_text_size, info.world.menu_screen == .settings);
    addMainMenuButton(ui, "menu_quit", "Quit to Desktop", left, top + (button_height + button_gap) * 3, button_width, button_height, button_text_size, false);

    if (ui.isActive("menu_singleplayer")) {
        info.world.menu_screen = .main;
    }
    if (ui.isActive("menu_multiplayer")) {
        info.world.menu_screen = .multiplayer;
        if (!network_manager.server_list.refresh and network_manager.server_list.count == 0) {
            network_manager.server_list.refresh = true;
        }
    }
    if (ui.isActive("menu_settings")) {
        info.world.menu_screen = .settings;
    }
    if (ui.isActive("menu_quit")) {
        info.world.request_quit = true;
    }

    switch (info.world.menu_screen) {
        .main => menuTuningPanel(info, ui, panel_left, panel_top, panel_width),
        .multiplayer => try multiplayerPanel(network_manager, ui, panel_left, panel_top, panel_width),
        .settings => settingsPanel(ui, panel_left, panel_top, panel_width),
    }
}

fn addMainMenuButton(ui: *Ui, name: []const u8, text: []const u8, left: f32, top: f32, width: f32, height: f32, text_size: f32, selected: bool) void {
    const hot = ui.isHot(name);
    const bg = if (selected or hot)
        nz.color.Rgba(f32).new(0.88, 0.55, 0.08, 1)
    else
        nz.color.Rgba(f32).new(0.02, 0.025, 0.025, 1);
    const fg = if (selected or hot)
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

fn menuViewportManipulator(info: *const Info, ui: *Ui, controller: *const Controller) void {
    const tuning = &info.world.menu_tuning;
    const viewport_active = ui.isActive("menu_viewport") or ui.isActive("menu_bozo_handle");
    const viewport_hot = ui.isHot("menu_viewport") or ui.isHot("menu_bozo_handle");
    const mouse_delta: [2]f32 = .{ @floatCast(controller.mouse_delta[0]), @floatCast(controller.mouse_delta[1]) };
    const wheel: f32 = @floatCast(controller.mouse_wheel);
    const basis = menuCameraBasis(tuning.*);

    if (ui.isActive("menu_bozo_handle")) tuning.edit_mode = .bozo;

    if (viewport_active) {
        switch (tuning.edit_mode) {
            .camera => {
                tuning.camera_yaw -= mouse_delta[0] * 0.006;
                tuning.camera_pitch = std.math.clamp(tuning.camera_pitch - mouse_delta[1] * 0.006, -1.2, 0.6);
            },
            .planet => {
                tuning.planet_position += nz.vec.scale(basis.right, mouse_delta[0] * 0.055);
                tuning.planet_position += nz.vec.scale(basis.up, mouse_delta[1] * 0.055);
                tuning.camera_target += nz.vec.scale(basis.right, mouse_delta[0] * 0.055);
                tuning.camera_target += nz.vec.scale(basis.up, mouse_delta[1] * 0.055);
            },
            .bozo => {
                tuning.bozo_screen[0] = std.math.clamp(tuning.bozo_screen[0] + mouse_delta[0] / ui.screen_width, 0.05, 0.95);
                tuning.bozo_screen[1] = std.math.clamp(tuning.bozo_screen[1] + mouse_delta[1] / ui.screen_heigth, 0.05, 0.95);
            },
        }
    }

    if (viewport_hot and wheel != 0) {
        switch (tuning.edit_mode) {
            .camera => tuning.camera_distance = std.math.clamp(tuning.camera_distance * std.math.pow(f32, 0.9, wheel), 18, 95),
            .planet => {
                tuning.planet_position += nz.vec.scale(basis.forward, wheel * 1.4);
                tuning.camera_target += nz.vec.scale(basis.forward, wheel * 1.4);
            },
            .bozo => tuning.bozo_surface_offset = std.math.clamp(tuning.bozo_surface_offset + wheel * 0.18, 0.5, 8),
        }
    }

    ui.add(null, .{
        .name = "menu_viewport",
        .size = .{ .fixed = .{ .heigth = ui.screen_heigth, .width = ui.screen_width } },
        .color = .new(0, 0, 0, 0),
    });

    const handle_size: f32 = 18;
    ui.add(null, .{
        .name = "menu_bozo_handle",
        .size = .{ .fixed = .{ .heigth = handle_size, .width = handle_size } },
        .offset = .{
            .left = tuning.bozo_screen[0] * ui.screen_width - handle_size * 0.5,
            .top = tuning.bozo_screen[1] * ui.screen_heigth - handle_size * 0.5,
        },
        .color = if (tuning.edit_mode == .bozo or ui.isHot("menu_bozo_handle")) .new(0.88, 0.55, 0.08, 1) else .new(0.94, 0.96, 0.9, 0.86),
    });
}

const MenuCameraBasis = struct {
    forward: nz.Vec3(f32),
    right: nz.Vec3(f32),
    up: nz.Vec3(f32),
};

fn menuCameraBasis(tuning: system.World.MenuTuning) MenuCameraBasis {
    const pitch = std.math.clamp(tuning.camera_pitch, -1.2, 0.6);
    const cos_pitch = @cos(pitch);
    const forward: nz.Vec3(f32) = nz.vec.normalize(@as(nz.Vec3(f32), .{
        @sin(tuning.camera_yaw) * cos_pitch,
        @sin(pitch),
        -@cos(tuning.camera_yaw) * cos_pitch,
    }));
    var right = nz.vec.cross(forward, @as(nz.Vec3(f32), .{ 0, 1, 0 }));
    if (nz.vec.length(right) < 0.001) right = @as(nz.Vec3(f32), .{ 1, 0, 0 });
    right = nz.vec.normalize(right);
    const up = nz.vec.normalize(nz.vec.cross(right, forward));
    return .{ .forward = forward, .right = right, .up = up };
}

fn menuTuningPanel(info: *const Info, ui: *Ui, left: f32, top: f32, width: f32) void {
    const panel_width = std.math.clamp(width, @as(f32, 280), @as(f32, 420));
    const tuning = &info.world.menu_tuning;
    const panel_height: f32 = 128;

    ui.add(null, .{
        .size = .{ .fixed = .{ .heigth = panel_height, .width = panel_width } },
        .offset = .{ .left = left, .top = top },
        .color = .new(0.02, 0.025, 0.025, 0.72),
    });

    const mode_width = (panel_width - 32) / 3;
    addModeButton(ui, "menu_mode_camera", "Camera", left + 8, top + 8, mode_width, tuning.edit_mode == .camera);
    addModeButton(ui, "menu_mode_planet", "Planet", left + 12 + mode_width, top + 8, mode_width, tuning.edit_mode == .planet);
    addModeButton(ui, "menu_mode_bozo", "Bozo", left + 16 + mode_width * 2, top + 8, mode_width, tuning.edit_mode == .bozo);

    if (ui.isActive("menu_mode_camera")) tuning.edit_mode = .camera;
    if (ui.isActive("menu_mode_planet")) tuning.edit_mode = .planet;
    if (ui.isActive("menu_mode_bozo")) tuning.edit_mode = .bozo;

    addReadout(ui, left + 10, top + 44, panel_width - 20, ui.print(
        "cam yaw {d:.2} pitch {d:.2} dist {d:.1}",
        .{ tuning.camera_yaw, tuning.camera_pitch, tuning.camera_distance },
    ));
    addReadout(ui, left + 10, top + 66, panel_width - 20, ui.print(
        "planet {d:.1} {d:.1} {d:.1}",
        .{ tuning.planet_position[0], tuning.planet_position[1], tuning.planet_position[2] },
    ));
    addReadout(ui, left + 10, top + 88, panel_width - 20, ui.print(
        "bozo screen {d:.2} {d:.2} out {d:.2}",
        .{ tuning.bozo_screen[0], tuning.bozo_screen[1], tuning.bozo_surface_offset },
    ));
}

fn addModeButton(ui: *Ui, name: []const u8, text: []const u8, left: f32, top: f32, width: f32, active: bool) void {
    const hot = ui.isHot(name);
    ui.add(null, .{
        .name = name,
        .size = .{ .fixed = .{ .heigth = 26, .width = width } },
        .offset = .{ .left = left, .top = top },
        .color = if (active or hot) .new(0.88, 0.55, 0.08, 1) else .new(0.08, 0.085, 0.08, 1),
        .child_anchor = .{ .x = .center, .y = .center },
        .text = .{
            .data = text,
            .size = 16,
            .color = if (active or hot) .new(0.02, 0.02, 0.015, 1) else .new(0.94, 0.96, 0.9, 1),
        },
    });
}

fn addReadout(ui: *Ui, left: f32, top: f32, width: f32, text: []const u8) void {
    ui.add(null, .{
        .size = .{ .fixed = .{ .heigth = 18, .width = width } },
        .offset = .{ .left = left, .top = top },
        .text = .{ .data = text, .size = 13, .color = .new(0.78, 0.82, 0.76, 1) },
    });
}

fn multiplayerPanel(network_manager: *NetworkManager, ui: *Ui, left: f32, top: f32, width: f32) !void {
    const row_height: f32 = 42;
    const row_gap: f32 = 8;
    const panel_width = @max(@as(f32, 260), width);

    ui.add(null, .{
        .name = "menu_refresh",
        .size = .{ .fixed = .{ .heigth = row_height, .width = panel_width } },
        .offset = .{ .left = left, .top = top },
        .color = if (ui.isHot("menu_refresh")) .new(0.14, 0.14, 0.12, 0.92) else .new(0.02, 0.025, 0.025, 0.82),
        .child_anchor = .{ .x = .center, .y = .center },
        .text = .{ .data = "Refresh Servers", .size = 26, .color = .new(0.94, 0.96, 0.9, 1) },
    });
    if (ui.isActive("menu_refresh") and network_manager.server_list.refresh == false) {
        network_manager.server_list.refresh = true;
    }

    if (network_manager.server_list.count == 0) {
        ui.add(null, .{
            .size = .{ .fixed = .{ .heigth = row_height, .width = panel_width } },
            .offset = .{ .left = left, .top = top + row_height + row_gap },
            .color = .new(0.02, 0.025, 0.025, 0.62),
            .child_anchor = .{ .x = .center, .y = .center },
            .text = .{
                .data = if (network_manager.server_list.refresh) "Searching for servers" else "No servers found",
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

fn settingsPanel(ui: *Ui, left: f32, top: f32, width: f32) void {
    const row_height: f32 = 42;
    const row_gap: f32 = 8;
    const panel_width = @max(@as(f32, 260), width);
    const rows = [_][]const u8{
        "Mouse Sensitivity",
        "Fullscreen",
        "Audio",
    };

    for (rows, 0..) |row, i| {
        ui.add(null, .{
            .size = .{ .fixed = .{ .heigth = row_height, .width = panel_width } },
            .offset = .{ .left = left, .top = top + (row_height + row_gap) * @as(f32, @floatFromInt(i)) },
            .color = .new(0.02, 0.025, 0.025, 0.82),
            .child_anchor = .{ .x = .center, .y = .center },
            .text = .{ .data = row, .size = 24, .color = .new(0.94, 0.96, 0.9, 1) },
        });
    }
}

fn serverList(network_manager: *NetworkManager, ui: *Ui) !void {
    ui.add(null, .{
        .name = "root",
        .size = .{ .fixed = .{
            .heigth = 500,
            .width = 400,
        } },
        .offset = .{ .left = (ui.screen_width - 400) / 2, .top = (ui.screen_heigth - 500) / 2 },
        .color = .new(0.5, 0.5, 0.5, 0.8),
        .axis_align = .verical,
        .children = &.{
            .{
                .name = "servers",
                .axis_align = .verical,
                .color = .grey,
                .size = .{
                    .percent = .{
                        .heigth = 0.8,
                        .width = 1.0,
                    },
                },
            },
            .{
                .name = "buttons",
                .axis_align = .horizontal,
                .child_anchor = .{ .x = .center, .y = .center },
                .size = .{
                    .percent = .{
                        .heigth = 0.2,
                        .width = 1.0,
                    },
                },
                .color = .new(0.1, 0.1, 0.1, 1),
                .children = &.{
                    .{ .size = .{
                        .fixed = .{
                            .heigth = 40,
                            .width = 100,
                        },
                    }, .color = if (ui.isHot("refresh")) .new(0.2, 0.2, 0.2, 1) else .grey, .name = "refresh", .text = .{ .data = "Refresh" } },
                },
            },
        },
    });
    for (0..network_manager.server_list.count) |i| {
        const server = &network_manager.server_list.servers[i];
        ui.add("servers", .{
            .name = &server.id_str,
            .text = .{ .data = &server.id_str },
            .size = .{ .percent = .{
                .heigth = 0.2,
                .width = 1.0,
            } },
            .color = if (ui.isHot(&server.id_str)) .new(0.2, 0.2, 0.2, 1) else .grey,
        });
        if (ui.isActive(&server.id_str)) {
            try network_manager.steam_client.connectToServer(server.steam_id);
            std.log.debug("connect to {d}", .{server.steam_id});
        }
    }
    if (ui.isActive("refresh") and network_manager.server_list.refresh == false) {
        network_manager.server_list.refresh = true;
    }
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
        // const inventory_heigth: f32 = ui.screen_heigth * 0.07;
        ui.add(null, .{
            .name = "inventory",
            .offset = .{ .top = ui.screen_heigth * 0.05, .left = ui.screen_width / 2 - inventory_width / 2 },
            .size = .{ .percent = .{ .width = 0.8, .heigth = 0.07 } },
            .color = .new(0.5, 0.5, 0.5, 0.4),
            .axis_align = .horizontal,
            .gap = 10,
        });
        for (std.enums.values(shared.Item.Kind)) |item_kind| {
            const amount = player.inventory.get(item_kind);
            if (amount == 0) continue;
            const amount_text = ui.print("{d}", .{amount});
            ui.add("inventory", .{
                .size = .{ .percent = .{
                    .heigth = 1,
                    .width = 0.1,
                } },
                .color = .new(1, 1, 1, 1),
                .name = ui.print("{t}", .{item_kind}),
                .texture = switch (item_kind) {
                    .health => .oxygen_tank,
                    .speed => .energy_drink,
                    .damage, .attack_speed => .damage_item,
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
                        null,
                        .{
                            .size = .{ .fixed = .{ .heigth = 0, .width = 0 } },
                            .text = .{ .data = ui.print("Teleport Charge: {d:.2}", .{teleporter.charged}) },
                            .offset = .{ .top = ui.screen_heigth / 10, .left = ui.screen_width * 0.05 },
                        },
                    );
                }
            }
        }
    }
}
