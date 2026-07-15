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
        .left_click = controller.input_map.keys.mouse_button_left,
        .right_click = controller.input_map.keys.mouse_button_right,
    });
    if (network_manager.steam_client.server_conn == 0) {
        try serverList(network_manager, ui);
    } else {
        try inGame(info, ui);
    }

    ui.end();
}

fn serverList(network_manager: *NetworkManager, ui: *Ui) !void {
    const root_width: f32 = 560;
    const root_heigth: f32 = 660;
    const server_list_heigth: f32 = 540;
    const button_heigth: f32 = root_heigth - server_list_heigth;

    if (network_manager.host_state != .none) {
        ui.add(null, .{
            .name = "root",
            .size = .{ .fixed = .{
                .heigth = root_heigth,
                .width = root_width,
            } },
            .offset = .{ .left = (ui.screen_width - root_width) / 2, .top = (ui.screen_heigth - root_heigth) / 2 },
            .color = .new(0.5, 0.5, 0.5, 0.8),
            .child_anchor = .{ .x = .center, .y = .center },
            .children = &.{
                .{
                    .name = "hosting",
                    .size = .{ .fixed = .{ .heigth = 0, .width = 0 } },
                    .child_anchor = .{ .x = .center, .y = .center },
                    .text = .{ .data = "hosting..." },
                },
            },
        });
        return;
    }
    ui.add(null, .{
        .name = "root",
        .size = .{ .fixed = .{
            .heigth = root_heigth,
            .width = root_width,
        } },
        .offset = .{ .left = (ui.screen_width - root_width) / 2, .top = (ui.screen_heigth - root_heigth) / 2 },
        .color = .new(0.5, 0.5, 0.5, 0.8),
        .axis_align = .verical,
        .children = &.{
            .{
                .name = "servers",
                .axis_align = .verical,
                .gap = 6,
                .color = .grey,
                .size = .{ .fixed = .{ .heigth = server_list_heigth, .width = root_width } },
            },
            .{
                .name = "buttons",
                .axis_align = .horizontal,
                .gap = 10,
                .child_anchor = .{ .x = .center, .y = .center },
                .size = .{ .fixed = .{ .heigth = button_heigth, .width = root_width } },
                .color = .new(0.1, 0.1, 0.1, 1),
                .children = &.{
                    .{ .size = .{
                        .fixed = .{
                            .heigth = 40,
                            .width = 100,
                        },
                    }, .color = if (ui.isHot("refresh")) .new(0.2, 0.2, 0.2, 1) else .grey, .name = "refresh", .text = .{ .data = "Refresh" } },
                    .{ .size = .{
                        .fixed = .{
                            .heigth = 40,
                            .width = 100,
                        },
                    }, .color = if (ui.isHot("host")) .new(0.2, 0.2, 0.2, 1) else .grey, .name = "host", .text = .{ .data = "Host" } },
                },
            },
        },
    });
    for (0..network_manager.server_list.count) |i| {
        const server = &network_manager.server_list.servers[i];
        const id = serverId(server);
        const title = clippedText(ui, serverTitle(server), 42);
        const tags = serverTags(server);
        const host = tagValue(tags, "host");
        const players = tagValue(tags, "players");
        const host_text = if (host.len == 0)
            "Host: unknown"
        else
            ui.print("Host: {s}", .{clippedText(ui, host, 36)});
        const player_text = if (players.len == 0)
            ui.print("Players: {d}/{d}", .{ @max(server.player_count, 0), @max(server.max_players, 0) })
        else
            ui.print("Players: {s}", .{clippedText(ui, players, 54)});

        ui.add("servers", .{
            .name = id,
            .axis_align = .verical,
            .gap = 2,
            .child_anchor = .{ .x = .start, .y = .center },
            .size = .{ .fixed = .{ .heigth = 60, .width = root_width } },
            .color = if (ui.isHot(id)) .new(0.2, 0.2, 0.2, 1) else .grey,
            .children = &.{
                .{
                    .size = .{ .fixed = .{ .heigth = 22, .width = root_width } },
                    .offset = .{ .left = 12, .top = 0 },
                    .text = .{ .data = title, .size = 20 },
                },
                .{
                    .size = .{ .fixed = .{ .heigth = 16, .width = root_width } },
                    .offset = .{ .left = 12, .top = 0 },
                    .text = .{ .data = host_text, .size = 14, .color = .new(0.9, 0.9, 0.9, 1) },
                },
                .{
                    .size = .{ .fixed = .{ .heigth = 16, .width = root_width } },
                    .offset = .{ .left = 12, .top = 0 },
                    .text = .{ .data = player_text, .size = 14, .color = .new(0.9, 0.9, 0.9, 1) },
                },
            },
        });
        if (ui.isActive(id)) {
            try network_manager.steam_client.connectToServer(server.steam_id);
            std.log.debug("connect to {d}", .{server.steam_id});
        }
    }
    if (ui.isActive("refresh") and network_manager.server_list.refresh == false) {
        network_manager.server_list.refresh = true;
    }
    if (ui.isActive("host") and network_manager.host_state == .none) {
        network_manager.host_state = .requested;
    }
}

fn serverId(server: *const shared.SteamNet.Client.ServerInfo) []const u8 {
    const id = std.mem.sliceTo(server.id_str[0..], 0);
    return if (id.len == 0) server.id_str[0..] else id;
}

fn serverTitle(server: *const shared.SteamNet.Client.ServerInfo) []const u8 {
    const title = std.mem.sliceTo(server.name[0..], 0);
    return if (title.len == 0) serverId(server) else title;
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

fn inGame(info: *const Info, ui: *Ui) !void {
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
                .axis_align = .verical,
            },
        );
        ui.add("info", .{
            .size = .{ .percent = .{ .heigth = 1, .width = 0.5 } },
            .text = .{ .data = ui.print("Stage: {d}", .{info.world.stage}) },
        });
        ui.add("info", .{
            .size = .{ .percent = .{ .heigth = 1, .width = 0.5 } },
            .text = .{ .data = ui.print("Currency: {d}", .{10}) },
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
