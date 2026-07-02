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
        serverList(network_manager, ui);
    } else {
        try inGame(info, ui);
    }

    ui.end();
}

fn serverList(network_manager: *NetworkManager, ui: *Ui) void {
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
                .size = .{
                    .percent = .{
                        .heigth = 0.8,
                        .width = 1.0,
                    },
                },
            },
            .{ .name = "buttons", .axis_align = .horizontal, .child_anchor = .{ .x = .center, .y = .center }, .size = .{
                .percent = .{
                    .heigth = 0.2,
                    .width = 1.0,
                },
            }, .color = .new(0.1, 0.1, 0.1, 1), .children = &.{
                .{ .size = .{
                    .fixed = .{
                        .heigth = 40,
                        .width = 100,
                    },
                }, .color = if (ui.isHot("refresh")) .new(0.2, 0.2, 0.2, 1) else .grey, .name = "refresh", .text = .{ .data = "Refresh" } },
            } },
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
            ui.add("inventory", .{
                .text = .{ .data = ui.print("{t} : {d}", .{ item_kind, amount }) },
                .size = .{ .percent = .{
                    .heigth = 1,
                    .width = 0.1,
                } },
                .color = .new(1, 1, 1, 1),
                .texture_index = 2,
            });
        }
        // ui.add(null, .{
        //     .size = .{ .percent = .{
        //         .heigth = 1,
        //         .width = 1,
        //     } },
        //     .texture_index = 1,
        // });
        ui.add(null, .{
            .name = "stats",
            .offset = .{ .top = ui.screen_heigth * 0.8, .left = ui.screen_width * 0.8 },
            .size = .{ .fixed = .{ .width = 200, .heigth = 200 } },
            .color = .new(0.5, 0.5, 0.5, 0.7),
            .axis_align = .verical,
            .gap = 10,
        });
        for (std.enums.values(shared.Stat.Kind)) |stat_kind| {
            const stat = player.stats.get(stat_kind);
            ui.add("stats", .{
                .text = .{ .data = ui.print("{t} : {d:.2}", .{ stat_kind, stat.current }) },
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
