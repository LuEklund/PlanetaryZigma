const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const system = @import("../../system.zig");
const Info = system.Info;
const Ui = @import("../../Ui.zig");
const Renderer = @import("../../Renderer.zig");
const NetworkManager = @import("../NetworkManager.zig");
const Controller = @import("../Controller.zig");
const Options = @import("../../Options.zig");
const Hud = @import("../Hud.zig");
const DamagePopup = @import("DamagePopup.zig");
const Request = Hud.Request;
const OptionsTab = Hud.OptionsTab;

pub fn update(info: *const Info, network_manager: *NetworkManager, ui: *Ui, texture_table: *Renderer.TextureTable, options: *Options, damage_popups: *const DamagePopup.List) !void {
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

    addChat(info, ui);

    if (info.world.getPtr(info.world.player_id)) |player| {
        addNameTags(info, ui);
        addEnemyHealthBars(info, ui);
        addDamagePopups(info, ui, damage_popups);

        const health_current = player.stats.current.get(.health);
        const health_max = player.stats.max.get(.health);
        const healthbar_heigth: f32 = 50;
        addHealthBar(ui, .{
            .left = 10,
            .top = ui.screen_heigth - healthbar_heigth - 10,
            .width = 200,
            .heigth = healthbar_heigth,
            .fraction = health_current / health_max,
            .fill_color = .new(0, 1, 0, 1),
            .text = .{ .data = ui.print("{d:.0} / {d}", .{ health_current, health_max }), .size = 40 },
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
            .color = .new(0.5, 0.5, 0.5, 0.2),
            .axis_align = .horizontal,
            .gap = 10,
        });
        for (std.enums.values(shared.Item)) |item_kind| {
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
                .texture = texture_table.handle(shared.Item.spec(item_kind).icon),
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
        for (std.enums.values(shared.Item)) |item_kind| {
            const amount = player.inventory.get(item_kind);
            if (amount == 0) continue;
            if (ui.isHot(ui.print("{t}", .{item_kind}))) {
                const attributes = item_kind.attributes();
                var tool_tip_text: []const u8 = "";
                for (std.enums.values(shared.Stats.Kind)) |stat_kind| {
                    const value = attributes.get(stat_kind);
                    if (value != 0) {
                        tool_tip_text = ui.print("{s}{t}: {d}", .{ tool_tip_text, stat_kind, value });
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
                        .texture = texture_table.handle(Renderer.TextureTable.crosshair_texture_path),
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
            for (std.enums.values(shared.Stats.Kind)) |stat_kind| {
                ui.add("stats", .{
                    .text = .{ .data = ui.print("{t} : {d:.2}", .{ stat_kind, player.stats.current.get(stat_kind) }) },
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
                total_boss_health += boss.stats.current.get(.health);
                total_boss_max_health += boss.stats.max.get(.health);
            }
            const boss_healthbar_width: f32 = (ui.screen_width * 0.9);
            addHealthBar(ui, .{
                .left = ui.screen_width / 2 - boss_healthbar_width / 2,
                .top = 20,
                .width = boss_healthbar_width,
                .heigth = 30,
                .fraction = total_boss_health / total_boss_max_health,
                .fill_color = .new(1, 0, 0, 1),
            });
        }
    }
}

fn addChat(info: *const Info, ui: *Ui) void {
    const chat = &info.world.chat;
    const text_size: f32 = 18;
    const line_heigth: f32 = 22;
    const left: f32 = 12;
    var top = ui.screen_heigth - 70 - line_heigth;

    if (chat.open) {
        const input_text = ui.print("> {s}_", .{chat.text()});
        const size = ui.textSize(input_text, text_size);
        ui.add(null, .{
            .offset = .{ .left = left, .top = top },
            .size = .{ .fixed = .{ .width = @max(size.width + 8, 240), .heigth = line_heigth } },
            .color = .new(0, 0, 0, 0.6),
            .child_anchor = .{ .x = .start, .y = .center },
            .children = &.{.{
                .size = .{ .fixed = size },
                .text = .{ .data = input_text, .size = text_size },
            }},
        });
    }

    var index = chat.count();
    while (index > 0) {
        index -= 1;
        const line = chat.get(index);
        if (!chat.open and info.elapsed_time - line.time > system.Chat.visible_seconds) break;
        top -= line_heigth;
        const size = ui.textSize(line.slice(), text_size);
        ui.add(null, .{
            .offset = .{ .left = left, .top = top },
            .size = .{ .fixed = .{ .width = size.width + 8, .heigth = line_heigth } },
            .color = .new(0, 0, 0, 0.45),
            .child_anchor = .{ .x = .start, .y = .center },
            .children = &.{.{
                .size = .{ .fixed = size },
                .text = .{ .data = line.slice(), .size = text_size },
            }},
        });
    }
}

fn addHealthBar(ui: *Ui, args: struct {
    left: f32,
    top: f32,
    width: f32,
    heigth: f32,
    fraction: f32,
    fill_color: nz.color.Rgba(f32),
    text: ?Ui.Layout.Text = null,
}) void {
    const fraction = std.math.clamp(args.fraction, 0, 1);
    ui.add(null, .{
        .offset = .{ .left = args.left, .top = args.top },
        .size = .{ .fixed = .{ .width = args.width, .heigth = args.heigth } },
        .color = .new(0, 0, 0, 0.55),
    });
    ui.add(null, .{
        .offset = .{ .left = args.left, .top = args.top },
        .size = .{ .fixed = .{ .width = args.width * fraction, .heigth = args.heigth } },
        .color = args.fill_color,
    });
    if (args.text) |bar_text| ui.add(null, .{
        .offset = .{ .left = args.left, .top = args.top },
        .size = .{ .fixed = .{ .width = args.width, .heigth = args.heigth } },
        .child_anchor = .{ .x = .center, .y = .center },
        .text = bar_text,
    });
}

fn addEnemyHealthBars(info: *const Info, ui: *Ui) void {
    const bar_width: f32 = 46;
    const bar_heigth: f32 = 4;
    const view_proj = info.world.camera.viewProj(ui.screen_width / ui.screen_heigth);
    for (info.world.entities.values()) |*entity| {
        if (entity.kind != .enemy) continue;
        const health_current = entity.stats.current.get(.health);
        const health_max = entity.stats.max.get(.health);
        if (health_max <= 0 or health_current <= 0 or health_current >= health_max) continue;

        const up = shared.planet.up(entity.transform.position) orelse entity.transform.rotation.rotateVec(.{ 0, 1, 0 });
        const bar_position = entity.transform.position + nz.vec.scale(up, 1.3 * entity.transform.scale[1]);
        if (isOccludedByPlanet(info.world.camera.transform.position, bar_position, info.world.planet_radius)) continue;
        const screen = ui.worldToScreen(view_proj, bar_position) orelse continue;

        addHealthBar(ui, .{
            .left = screen[0] - bar_width / 2,
            .top = screen[1] - bar_heigth,
            .width = bar_width,
            .heigth = bar_heigth,
            .fraction = health_current / health_max,
            .fill_color = .new(0.9, 0.2, 0.15, 0.9),
        });
    }
}

fn addDamagePopups(info: *const Info, ui: *Ui, damage_popups: *const DamagePopup.List) void {
    const view_proj = info.world.camera.viewProj(ui.screen_width / ui.screen_heigth);
    for (damage_popups.items()) |popup| {
        const up = shared.planet.up(popup.position) orelse .{ 0, 1, 0 };
        const world_position = popup.position + nz.vec.scale(up, 1.4 + popup.age * 1.6);
        const screen = ui.worldToScreen(view_proj, world_position) orelse continue;
        const alpha = 1 - popup.age / DamagePopup.lifetime;
        const rounded = @round(@abs(popup.amount) * 10) / 10;
        const text = if (popup.amount < 0)
            ui.print("+{d}", .{rounded})
        else
            ui.print("{d}", .{rounded});
        const text_size = ui.textSize(text, 24);
        ui.add(null, .{
            .offset = .{ .left = screen[0] - text_size.width / 2, .top = screen[1] },
            .size = .{ .fixed = text_size },
            .text = .{ .data = text, .size = 24, .color = .new(popup.color[0], popup.color[1], popup.color[2], alpha) },
        });
    }
}

fn addNameTags(info: *const Info, ui: *Ui) void {
    const label_size: f32 = 18;
    const padding_x: f32 = 8;
    const padding_y: f32 = 3;
    const view_proj = info.world.camera.viewProj(ui.screen_width / ui.screen_heigth);

    for (info.world.entities.values()) |*entity| {
        if (entity.kind != .player or entity.id == info.world.player_id) continue;

        const name = if (entity.player_name.len != 0)
            entity.player_name
        else
            ui.print("{s} {d}", .{ shared.default_player_name, @intFromEnum(entity.id) });

        const up = shared.planet.up(entity.transform.position) orelse entity.transform.rotation.rotateVec(.{ 0, 1, 0 });
        const tag_position = entity.transform.position + nz.vec.scale(up, 1.6);
        if (info.world.planet_radius > 0 and isOccludedByPlanet(info.world.camera.transform.position, tag_position, info.world.planet_radius)) continue;
        const screen = ui.worldToScreen(view_proj, tag_position) orelse continue;
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

//TODO: account for hills.
fn isOccludedByPlanet(camera_position: nz.Vec3(f32), tag_position: nz.Vec3(f32), planet_radius: f32) bool {
    const segment = tag_position - camera_position;
    const segment_len_sq = nz.vec.dot(segment, segment);
    if (segment_len_sq <= 0.0001) return false;
    const t = std.math.clamp(-nz.vec.dot(camera_position, segment) / segment_len_sq, 0, 1);
    const closest = camera_position + nz.vec.scale(segment, t);
    return nz.vec.length(closest) < planet_radius + 0.2;
}
