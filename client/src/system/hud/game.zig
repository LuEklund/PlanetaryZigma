const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const system = @import("../../system.zig");
const Info = system.Info;
const Ui = @import("../../Renderer/Vulkan/Ui.zig");
const Resources = @import("../../Renderer/Vulkan/Resources.zig");
const NetworkManager = @import("../NetworkManager.zig");
const Controller = @import("../Controller.zig");
const Options = @import("../../Options.zig");
const Hud = @import("../Hud.zig");
const Request = Hud.Request;
const OptionsTab = Hud.OptionsTab;

pub fn update(info: *const Info, network_manager: *NetworkManager, ui: *Ui, resources: *Resources, options: *Options) !void {
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
                .texture = resources.textureHandle(shared.Item.spec(item_kind).icon),
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
                .name = "info",
                .axis_align = .vertical,
                .size = .{ .percent = .{ .heigth = 1, .width = 0.2 } },
            },
        );
        const stage_text = ui.print("stage: {d}", .{info.world.stage});

        ui.add(
            "info",
            .{
                .name = "stage",
                .size = .{ .fixed = ui.textSize(stage_text, 18) },
                .text = .{ .data = stage_text, .size = 18 },
            },
        );
        if (info.world.getPtr(info.world.teleporter_id)) |entity| {
            const teleporter = entity.teleporter;
            // const active = entity.teleporter.active;
            ui.add(
                "info",
                .{
                    .size = .{ .percent = .{ .heigth = 1, .width = 1 } },
                    .text = .{
                        .data = ui.print("Teleport Charge: {d:.2}", .{teleporter.charged}),
                        .size = 18,
                    },
                },
            );
            // if (teleporter.charged != teleporter.max_charge and active) {
            // }
        }

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
                        .texture = resources.textureHandle(Resources.crosshair_texture_key),
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

        if (player.interacting != .none) {
            if (info.world.getPtr(player.interacting)) |entity| {
                ui.add(
                    null,
                    .{
                        .name = "interacting",
                        .size = .{ .fixed = .{ .heigth = 32, .width = 32 } },
                        .color = .new(0, 0, 0, 0.7),
                        .offset = .{ .left = ui.screen_width / 2 + 32, .top = ui.screen_heigth / 2 + 32 },
                        .gap = 5,
                    },
                );
                ui.add(
                    "interacting",
                    .{
                        .size = .{ .percent = .{ .heigth = 1, .width = 1 } },
                        .text = .{ .data = "E" },
                        .child_anchor = .{ .x = .center, .y = .center },
                    },
                );
                if (entity.kind == .lootbox) {
                    const cost_text = ui.print("${d}", .{entity.currency});
                    ui.add(
                        "interacting",
                        .{
                            .size = .{ .fixed = ui.textSize(cost_text, 32) },
                            .text = .{ .data = cost_text, .color = .new(1, 1, 0, 1) },
                            .child_anchor = .{ .x = .center, .y = .center },

                            .color = .new(0, 0, 0, 0.5),
                        },
                    );
                }
            }
        }
        if (info.world.teleporter_bosses.items.len > 0) {
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
