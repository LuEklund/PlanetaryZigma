const std = @import("std");
const nz = @import("shared").numz;
const shared = @import("shared");
const system = @import("../system.zig");
const tracy = @import("ztracy");
const Info = system.Info;
const Ui = @import("../Renderer/Vulkan/Ui.zig");
const NetworkManager = @import("NetworkManager.zig");
const Controller = @import("Controller.zig");

teleport_charge_text: [32]u8 = undefined,

pub fn update(self: *@This(), info: *const Info, network_manager: *NetworkManager, ui: *Ui, controller: *const Controller) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();

    const position: [2]f32 = .{ @floatCast(controller.mouse_pos[0]), @floatCast(controller.mouse_pos[1]) };
    ui.start(.{
        .position = .{ .left = position[0], .top = position[1] },
        .left_click = controller.input_map.keys.mouse_button_left,
        .right_click = controller.input_map.keys.mouse_button_right,
    });
    if (network_manager.steam_client.server_conn == 0) {
        ui.add(null, .{
            .name = "root",
            .size = .{ .fixed = .{
                .heigth = 500,
                .width = 400,
            } },
            .position = .center,
            .color = .new(0.5, 0.5, 0.5, 0.8),
            .axis_align = .verical,
            .children = &.{
                .{
                    .name = "servers",
                    .position = .{ .fixed = .{ .left = 0, .top = 0 } },
                    .axis_align = .verical,
                    .size = .{
                        .percent = .{
                            .heigth = 0.8,
                            .width = 1.0,
                        },
                    },
                },
                .{ .name = "buttons", .position = .{
                    .fixed = .{ .left = 0, .top = 0 },
                }, .axis_align = .horizontal, .size = .{
                    .percent = .{
                        .heigth = 0.2,
                        .width = 1.0,
                    },
                }, .color = .new(0.1, 0.1, 0.1, 1), .children = &.{
                    .{ .position = .center, .size = .{
                        .fixed = .{
                            .heigth = 40,
                            .width = 100,
                        },
                    }, .color = if (ui.isHot("refresh")) .new(0.2, 0.2, 0.2, 1) else .grey, .name = "refresh", .text = "Refresh" },
                } },
            },
        });
        for (0..network_manager.server_list.count) |i| {
            const server = &network_manager.server_list.servers[i];
            ui.add("servers", .{
                .name = &server.id_str,
                .text = &server.id_str,
                .position = .{ .fixed = .{ .left = 0, .top = 0 } },
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
    } else {
        if (info.world.getPtr(info.world.player_id)) |player| {
            const healthbar_width: f32 = 200 * player.health.current / player.health.max;
            const healthbar_heigth: f32 = 30;
            ui.add(null, .{
                .position = .{
                    .fixed = .{
                        .top = ui.screen_heigth - healthbar_heigth - 10,
                        .left = 10,
                    },
                },
                .size = .{ .fixed = .{ .heigth = healthbar_heigth, .width = healthbar_width } },
                .color = .new(1, 0, 0, 1),
            });

            const portal = info.world.getPtr(info.world.teleporter_id);
            const teleporter_active = if (portal) |entity| entity.teleporter.active else false;
            if (teleporter_active == false) {
                if (portal) |entity| {
                    if (nz.vec.length(player.transform.position - entity.transform.position) < shared.Teleporter.intertact_distance) {
                        ui.add(
                            null,
                            .{
                                .name = "active_teleport",
                                .size = .{ .fixed = .{ .heigth = 0, .width = 0 } },
                                .text = "E",
                                .position = .center,
                            },
                        );
                    }
                }
            } else {
                var total_boss_health: f32 = 0;
                var total_boss_max_health: f32 = 0;
                for (info.world.teleporter_bosses.items) |boss_id| {
                    const boss = info.world.getPtr(boss_id) orelse continue;
                    total_boss_health += boss.health.current;
                    total_boss_max_health += boss.health.max;
                }
                const boss_healthbar_width: f32 = (ui.screen_width * 0.9) * (total_boss_health / total_boss_max_health);
                const boss_healthbar_heigth: f32 = 30;
                ui.add(null, .{
                    .position = .{
                        .fixed = .{
                            .top = 20,
                            .left = ui.screen_width / 2 - boss_healthbar_width / 2,
                        },
                    },
                    .size = .{ .fixed = .{ .heigth = boss_healthbar_heigth, .width = boss_healthbar_width } },
                    .color = .new(1, 0, 0, 1),
                });
                if (portal) |entity| {
                    const teleporter = entity.teleporter;
                    if (teleporter.charged == teleporter.max_charge and info.world.teleporter_bosses.items.len == 0) {
                        if (nz.vec.length(player.transform.position - entity.transform.position) < shared.Teleporter.intertact_distance) {
                            ui.add(
                                null,
                                .{
                                    .name = "active_teleport",
                                    .size = .{ .fixed = .{ .heigth = 0, .width = 0 } },
                                    .text = "E",
                                    .position = .center,
                                },
                            );
                        }
                    } else {
                        const teleporter_text = try std.fmt.bufPrint(&self.teleport_charge_text, "Teleport Charge: {d:.2}", .{teleporter.charged});
                        ui.add(
                            null,
                            .{
                                .size = .{ .fixed = .{ .heigth = 0, .width = 0 } },
                                .text = teleporter_text,
                                .position = .{ .fixed = .{ .top = ui.screen_heigth / 10, .left = ui.screen_width * 0.05 } },
                            },
                        );
                    }
                }
            }
        }
    }

    ui.end();
}
