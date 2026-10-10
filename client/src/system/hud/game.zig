const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const dvui = @import("dvui");
const system = @import("../../System.zig");
const World = system.World;
const Assets = @import("graphics").Assets;
const Network = @import("../Network.zig");
const Options = @import("../../Options.zig");
const Hud = @import("../Hud.zig");
const DamagePopup = @import("DamagePopup.zig");
const style = @import("style.zig");
const Request = Hud.Request;

const margin: f32 = 12;

fn sideWidth(area: dvui.Rect) f32 {
    return std.math.clamp(area.w * 0.28, 180, 340);
}

pub fn update(
    hud: *Hud,
    world: *World,
    network: *Network,
    options: *Options,
    game_assets: *const Assets,
) void {
    const area = style.screen();
    const view_proj = world.camera.viewProj(world.options.fov_rad, area.w / area.h);

    if (world.getPtr(world.player_id)) |player| {
        addNameTags(world, view_proj);
        addPings(world, view_proj);
        addWorldHealthBars(world, view_proj);
        addDamagePopups(&hud.damage_popups, view_proj);
        addInventory(player, game_assets, area);
        addActionBar(world, player, game_assets, area);
        style.bar(
            .{ .x = margin, .y = area.h - 50 - margin, .w = 220, .h = 50 },
            player.health / player.max_health,
            style.rgba(.{ 0.1, 0.85, 0.2, 1 }),
        );
        dvui.label(@src(), "{d:.0} / {d:.0}", .{ player.health, player.max_health }, .{
            .rect = .{ .x = margin, .y = area.h - 50 - margin, .w = 220, .h = 50 },
            .font = style.font(24),
            .color_text = .fromColor(style.text),
            .gravity_x = 0.5,
            .gravity_y = 0.5,
        });
        if (options.show_crosshair) _ = dvui.image(@src(), .{
            .source = .{ .texture = style.texture(game_assets.textures.crosshair()) },
            .shrink = .both,
        }, .{
            .rect = .{ .x = area.w / 2 - 25, .y = area.h / 2 - 25, .w = 50, .h = 50 },
        });
        addInteractPrompt(world, player, area);
        addBossBar(world, area);
        hud.death_fade = Hud.approach(
            hud.death_fade,
            if (player.health <= 0) 1 else 0,
            world.delta_time,
            1.2,
        );
        if (hud.death_fade > 0) {
            const band = std.math.clamp(area.h * (1 - hud.death_fade), 96, area.h);
            const band_rect: dvui.Rect = .{
                .x = 0,
                .y = (area.h - band) / 2,
                .w = area.w,
                .h = band,
            };
            style.fillRect(band_rect, style.rgba(.{ 0, 0, 0, hud.death_fade }));
            dvui.labelNoFmt(
                @src(),
                "Died of cringe",
                .{},
                .{
                    .rect = band_rect,
                    .font = style.font(40),
                    .color_text = .fromColor(style.text),
                    .gravity_x = 0.5,
                    .gravity_y = 0.5,
                },
            );
        }
    }

    addTopLeft(world, area);
    addRightColumn(world, network, area);
    addChat(world, area);
}

fn addTopLeft(world: *World, area: dvui.Rect) void {
    var column = dvui.box(
        @src(),
        .{ .dir = .vertical },
        .{ .rect = .{ .x = margin, .y = margin, .w = sideWidth(area), .h = 120 } },
    );
    defer column.deinit();
    dvui.label(
        @src(),
        "{d:.0} fps",
        .{world.fps},
        .{ .font = style.font(22), .color_text = .fromColor(style.text_dim) },
    );
    if (world.getPtr(world.player_id)) |player| {
        dvui.label(@src(), "$ {d}", .{player.currency}, .{
            .font = style.font(26),
            .color_text = .fromColor(style.rgba(.{ 1, 0.85, 0.2, 1 })),
            .background = true,
            .color_fill = .fromColor(style.rgba(.{ 0, 0, 0, 0.35 })),
            .padding = .{ .x = 8, .w = 8, .y = 2, .h = 2 },
        });
    }
}

fn addRightColumn(world: *World, network: *Network, area: dvui.Rect) void {
    var column = dvui.box(
        @src(),
        .{ .dir = .vertical },
        .{
            .rect = .{
                .x = area.w - sideWidth(area) - margin,
                .y = margin,
                .w = sideWidth(area),
                .h = area.h * 0.6,
            },
        },
    );
    defer column.deinit();

    const ping = network.ping_milliseconds;
    const ping_color: [4]f32 = if (ping < 0) .{
        0.68,
        0.72,
        0.66,
        1,
    } else if (ping < 60) .{
        0.25,
        0.85,
        0.3,
        1,
    } else if (ping < 120) .{ 0.9, 0.78, 0.12, 1 } else .{ 0.9, 0.2, 0.15, 1 };
    if (ping < 0) {
        dvui.labelNoFmt(
            @src(),
            "-- ms",
            .{},
            .{
                .font = style.font(22),
                .color_text = .fromColor(style.rgba(ping_color)),
                .gravity_x = 1,
            },
        );
    } else {
        dvui.label(
            @src(),
            "{d} ms",
            .{ping},
            .{
                .font = style.font(22),
                .color_text = .fromColor(style.rgba(ping_color)),
                .gravity_x = 1,
            },
        );
    }
    if (world.stage > 0) {
        const run_minutes: u32 = @intFromFloat(world.difficulty.run_seconds / 60);
        const run_seconds: u32 = @intFromFloat(@mod(world.difficulty.run_seconds, 60));
        const heat = std.math.clamp((world.difficulty.coefficient - 1) / 6, 0, 1);
        dvui.label(@src(), "{s}  {d:0>2}:{d:0>2}  Lv {d:.0}", .{
            shared.Biome.forRadius(world.planet.planet_radius).name,
            run_minutes,
            run_seconds,
            world.difficulty.level,
        }, .{
            .font = style.font(22),
            .color_text = .fromColor(
                style.rgba(.{ 0.75 + 0.25 * heat, 0.8 - 0.6 * heat, 0.6 - 0.5 * heat, 1 }),
            ),
            .gravity_x = 1,
        });
    }
    addObjective(world);
}

fn sidePanel(src: std.builtin.SourceLocation) *dvui.BoxWidget {
    return dvui.box(src, .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = .fromColor(style.rgba(.{ 0, 0, 0, 0.4 })),
        .padding = .all(8),
        .margin = .{ .y = 6 },
    });
}

fn addObjective(world: *World) void {
    var panel = sidePanel(@src());
    defer panel.deinit();
    const boss_alive = world.teleporter_bosses.items.len > 0;
    dvui.label(
        @src(),
        "Stage {d}",
        .{world.stage},
        .{ .font = style.font(16), .color_text = .fromColor(style.text_dim) },
    );
    dvui.labelNoFmt(
        @src(),
        "Objective",
        .{},
        .{ .font = style.font(24), .color_text = .fromColor(style.text) },
    );
    const objective_options: dvui.Options = .{
        .font = style.font(20),
        .color_text = .fromColor(style.rgba(.{ 0.95, 0.85, 0.25, 1 })),
    };
    if (world.stage == 0) {
        var ready_count: usize = 0;
        var player_count: usize = 0;
        for (world.entities.values()) |*entity| {
            if (entity.kind != .player) continue;
            player_count += 1;
            if (entity.ready) ready_count += 1;
        }
        dvui.label(
            @src(),
            "E on the teleporter: ready ({d}/{d})",
            .{ ready_count, player_count },
            objective_options,
        );
    } else if (world.getPtr(
        world.teleporter_id,
    ) == null or world.getPtr(world.teleporter_id).?.teleporter.state == .idle) {
        dvui.labelNoFmt(@src(), "Find the teleporter", .{}, objective_options);
    } else {
        const teleporter = world.getPtr(world.teleporter_id).?.teleporter;
        if (teleporter.charged < teleporter.max_charge) dvui.label(
            @src(),
            "Charge the teleporter {d:.0}%",
            .{100 * teleporter.charged / teleporter.max_charge},
            objective_options,
        );
        if (boss_alive) dvui.labelNoFmt(@src(), "Defeat the boss", .{}, objective_options);
        if (!boss_alive and teleporter.charged >= teleporter.max_charge) dvui.labelNoFmt(
            @src(),
            "Enter the teleporter",
            .{},
            objective_options,
        );
    }
}

fn addInventory(player: *const World.Entity, game_assets: *const Assets, area: dvui.Rect) void {
    const icon_size: f32 = std.math.clamp(area.w / 30, 36, 56);
    const width = @max(icon_size, area.w - 2 * (sideWidth(area) + 2 * margin));
    var flow = dvui.flexbox(
        @src(),
        .{},
        .{
            .rect = .{
                .x = sideWidth(area) + 2 * margin,
                .y = margin,
                .w = width,
                .h = area.h * 0.3,
            },
        },
    );
    defer flow.deinit();
    for (std.enums.values(shared.Item.Kind), 0..) |item_kind, index| {
        const amount = player.inventory.get(item_kind);
        const item = shared.Item.get(item_kind);
        if (amount == 0 or item.is_equipment) continue;
        var slot = dvui.overlay(
            @src(),
            .{
                .id_extra = index,
                .min_size_content = .{ .w = icon_size, .h = icon_size },
                .margin = .all(3),
            },
        );
        defer slot.deinit();
        const image = dvui.image(
            @src(),
            .{
                .source = .{ .texture = style.texture(game_assets.textures.get(item_kind)) },
                .shrink = .both,
            },
            .{ .expand = .both },
        );
        dvui.label(
            @src(),
            "{d}",
            .{amount},
            .{
                .font = style.font(18),
                .color_text = .fromColor(style.text),
                .gravity_x = 1,
                .gravity_y = 1,
                .background = true,
                .color_fill = .fromColor(style.rgba(.{ 0, 0, 0, 0.6 })),
                .padding = .{ .x = 3, .w = 3 },
            },
        );
        dvui.tooltip(@src(), .{ .active_rect = image.borderRectScale().r }, "{s} ({t}): {s}", .{
            @tagName(item_kind),
            item.tier,
            item.description,
        }, .{
            .font = style.font(18),
            .color_text = .fromColor(tierColor(item.tier)),
            .color_fill = .fromColor(style.rgba(.{ 0.08, 0.08, 0.08, 0.92 })),
        });
    }
}

fn addActionBar(
    world: *World,
    player: *const World.Entity,
    game_assets: *const Assets,
    area: dvui.Rect,
) void {
    const slot: f32 = std.math.clamp(area.w / 16, 44, 84);
    const gap: f32 = slot / 10;
    const actions = [_]shared.entity.Action{ .primary, .secondary, .utility, .special, .equipment };
    const keys = [_][]const u8{ "LMB", "RMB", "Shift", "R", "Q" };
    const bar_width = actions.len * (slot + gap) + gap;
    const left = area.w - bar_width - margin;
    const top = area.h - slot - 2 * gap - margin;
    style.fillRect(
        .{ .x = left, .y = top, .w = bar_width, .h = slot + 2 * gap },
        style.rgba(.{ 0, 0, 0, 0.6 }),
    );
    const survivor = shared.Survivor.get(player.survivor);

    for (actions, keys, 0..) |action, key, index| {
        const rect: dvui.Rect = .{
            .x = left + gap + @as(f32, @floatFromInt(index)) * (slot + gap),
            .y = top + gap,
            .w = slot,
            .h = slot,
        };
        const cooldown_stat: shared.Item.Stat = switch (action) {
            .primary => .primary_cooldown,
            .secondary => .secondary_cooldown,
            .utility => .utility_cooldown,
            .special => .special_cooldown,
            .equipment => .equipment_cooldown,
        };
        const cooldown = player.stat(cooldown_stat);
        const remaining = std.math.clamp(
            (world.controller.cooldown.get(action) + cooldown - world.elapsed_time) / cooldown,
            0,
            1,
        );

        const texture = switch (action) {
            .primary => if (player.survivor == .commando) game_assets.textures.shoot() else null,
            .secondary => if (player.survivor == .commando) game_assets.textures.spread() else null,
            .equipment => equipped: {
                for (std.enums.values(shared.Item.Kind)) |item_kind| {
                    if (player.inventory.get(
                        item_kind,
                    ) > 0 and shared.Item.get(
                        item_kind,
                    ).is_equipment) break :equipped game_assets.textures.get(item_kind);
                }
                break :equipped null;
            },
            else => null,
        };
        if (texture) |handle| {
            _ = dvui.image(
                @src(),
                .{ .source = .{ .texture = style.texture(handle) } },
                .{ .id_extra = index, .rect = rect },
            );
        } else {
            style.fillRect(rect, style.rgba(.{ 0.16, 0.17, 0.2, 1 }));
            const name = if (action == .equipment) "empty" else if (survivor.abilities.get(
                action,
            )) |assigned| @tagName(
                assigned.skill,
            ) else "-";
            dvui.labelNoFmt(
                @src(),
                name,
                .{},
                .{
                    .id_extra = index,
                    .rect = rect,
                    .padding = .all(0),
                    .font = style.fitFont(name, 15, rect.w - 4),
                    .color_text = .fromColor(style.text),
                    .gravity_x = 0.5,
                    .gravity_y = 0.5,
                },
            );
        }
        if (remaining > 0) style.fillRect(
            .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h * remaining },
            style.rgba(.{ 0, 0, 0, 0.6 }),
        );
        dvui.labelNoFmt(
            @src(),
            key,
            .{},
            .{
                .id_extra = index,
                .rect = .{ .x = rect.x + 2, .y = rect.y + 2, .w = rect.w - 4, .h = 20 },
                .padding = .all(0),
                .font = style.font(14),
                .color_text = .fromColor(style.text_dim),
            },
        );
    }
}

fn addInteractPrompt(world: *World, player: *const World.Entity, area: dvui.Rect) void {
    if (player.interacting == .none) return;
    const entity = world.getPtr(player.interacting) orelse return;
    const options: dvui.Options = .{
        .rect = .{ .x = area.w / 2 + 32, .y = area.h / 2 + 32, .w = 160, .h = 34 },
        .font = style.font(24),
        .color_text = .fromColor(style.text),
        .background = true,
        .color_fill = .fromColor(style.rgba(.{ 0, 0, 0, 0.7 })),
        .padding = .{ .x = 8 },
    };
    if (entity.kind == .lootbox) {
        dvui.label(@src(), "E  ${d}", .{entity.currency}, options);
    } else {
        dvui.labelNoFmt(@src(), "E", .{}, options);
    }
}

fn addBossBar(world: *World, area: dvui.Rect) void {
    if (world.teleporter_bosses.items.len == 0) return;
    var health: f32 = 0;
    var max_health: f32 = 0;
    for (world.teleporter_bosses.items) |boss_id| {
        const boss = world.getPtr(boss_id) orelse continue;
        health += boss.health;
        max_health += boss.max_health;
    }
    const width = area.w * 0.4;
    style.bar(
        .{ .x = (area.w - width) / 2, .y = area.h * 0.2, .w = width, .h = 22 },
        if (max_health > 0) health / max_health else 0,
        style.rgba(.{ 0.9, 0.1, 0.1, 1 }),
    );
}

fn addChat(world: *World, area: dvui.Rect) void {
    const chat = &world.chat;
    const line_height: f32 = 24;
    var top = area.h - 50 - margin - 12 - line_height;
    const line_options: dvui.Options = .{
        .font = style.font(18),
        .color_text = .fromColor(style.text),
        .background = true,
        .padding = .{ .x = 6, .w = 6 },
    };
    if (chat.open) {
        var options = line_options;
        options.rect = .{ .x = margin, .y = top, .w = 420, .h = line_height };
        options.color_fill = .fromColor(style.rgba(.{ 0, 0, 0, 0.6 }));
        dvui.label(@src(), "> {s}_", .{chat.text()}, options);
    }
    var index = chat.count();
    while (index > 0) {
        index -= 1;
        const line = chat.get(index);
        if (!chat.open and world.elapsed_time - line.time > system.Chat.visible_seconds) break;
        top -= line_height;
        var options = line_options;
        options.id_extra = index;
        options.rect = .{ .x = margin, .y = top, .w = 420, .h = line_height };
        options.color_fill = .fromColor(style.rgba(.{ 0, 0, 0, 0.45 }));
        dvui.labelNoFmt(@src(), line.slice(), .{}, options);
    }
}

fn addWorldHealthBars(world: *World, view_proj: nz.Mat4x4(f32)) void {
    const bar_width: f32 = 46;
    const bar_height: f32 = 4;
    const reference_distance: f32 = 20;
    const camera_position = world.camera.transform.position;
    for (world.entities.values(), 0..) |*entity, index| {
        if (entity.max_health <= 0 or entity.id == world.player_id) continue;
        const important = entity.flags.is_teleporter_boss or entity.elite != .none;
        if (!important and (entity.health <= 0 or entity.health >= entity.max_health)) continue;
        const min_scale: f32 = if (important) 2.5 else 0.35;
        const max_scale: f32 = if (important) 4 else 1;

        const up = shared.Planet.up(
            entity.transform.position,
        ) orelse entity.transform.rotation.rotateVec(.{ 0, 1, 0 });
        const bar_position = entity.transform.position + nz.vec.scale(
            up,
            1.3 * entity.transform.scale[1],
        );
        const screen = style.worldToScreen(view_proj, bar_position) orelse continue;
        const scale = std.math.clamp(
            reference_distance / @max(nz.vec.distance(camera_position, bar_position), 0.001),
            min_scale,
            max_scale,
        );
        const width = bar_width * scale;
        const height = bar_height * scale;
        style.bar(
            .{ .x = screen[0] - width / 2, .y = screen[1] - height, .w = width, .h = height },
            entity.health / entity.max_health,
            style.rgba(.{ 0.9, 0.2, 0.15, 0.9 }),
        );
        if (entity.elite != .none) {
            const elite = shared.Elite.get(entity.elite);
            dvui.labelNoFmt(@src(), elite.name, .{}, .{
                .id_extra = index,
                .rect = .{
                    .x = screen[0] - 100,
                    .y = screen[1] - height - 18 * scale,
                    .w = 200,
                    .h = 18 * scale,
                },
                .font = style.font(12 * scale),
                .color_text = .fromColor(
                    style.rgba(.{ elite.tint[0], elite.tint[1], elite.tint[2], 1 }),
                ),
                .gravity_x = 0.5,
            });
        }
    }
}

fn addDamagePopups(damage_popups: *const DamagePopup.List, view_proj: nz.Mat4x4(f32)) void {
    for (damage_popups.items(), 0..) |popup, index| {
        const up = shared.Planet.surfaceUp(popup.position);
        const screen = style.worldToScreen(
            view_proj,
            popup.position + nz.vec.scale(up, 1.4 + popup.age * 1.6),
        ) orelse continue;
        const alpha = 1 - popup.age / DamagePopup.lifetime;
        const rounded = @round(@abs(popup.amount) * 10) / 10;
        dvui.label(@src(), "{s}{d}", .{ if (popup.amount < 0) "+" else "", rounded }, .{
            .id_extra = index,
            .rect = .{ .x = screen[0] - 60, .y = screen[1], .w = 120, .h = 32 },
            .padding = .all(0),
            .font = style.font(24),
            .color_text = .fromColor(
                style.rgba(.{ popup.color[0], popup.color[1], popup.color[2], alpha }),
            ),
            .gravity_x = 0.5,
        });
    }
}

fn addPings(world: *World, view_proj: nz.Mat4x4(f32)) void {
    for (world.pings, 0..) |ping, index| {
        if (ping.expires_at <= world.elapsed_time) continue;
        const target = world.getPtr(ping.event.target);
        const position = if (target) |entity| entity.transform.position else ping.event.position;
        const up = shared.Planet.up(position) orelse continue;
        const screen = style.worldToScreen(
            view_proj,
            position + nz.vec.scale(up, 2),
        ) orelse continue;
        const remaining = (ping.expires_at - world.elapsed_time) / World.ping_seconds;
        style.ring(.{ screen[0], screen[1] + 14 }, 9, 3, remaining, style.accent);
        const pinger = world.getPtr(ping.event.pinger);
        const name = if (pinger) |player| player.player_name.slice() else "";
        const what = if (target) |entity| kindLabel(entity.kind) else "here";
        var buffer: [96]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "v {s}: {s}", .{ name, what }) catch "v";
        style.floatingLabel(@src(), index, text, .{ screen[0], screen[1] - 30 }, 22, style.accent);
    }
}

fn kindLabel(kind: shared.entity.Kind) []const u8 {
    return switch (kind) {
        .enemy => |enemy| @tagName(enemy),
        .item_pickup => "item",
        else => @tagName(kind),
    };
}

fn addNameTags(world: *World, view_proj: nz.Mat4x4(f32)) void {
    for (world.entities.values(), 0..) |*entity, index| {
        if (entity.kind != .player or entity.id == world.player_id) continue;
        const up = shared.Planet.up(
            entity.transform.position,
        ) orelse entity.transform.rotation.rotateVec(.{ 0, 1, 0 });
        const screen = style.worldToScreen(
            view_proj,
            entity.transform.position + nz.vec.scale(up, 1.6),
        ) orelse continue;
        const name = if (entity.player_name.slice().len != 0) entity.player_name.slice() else shared.default_player_name;
        style.floatingLabel(@src(), index, name, .{ screen[0], screen[1] - 30 }, 18, style.text);
    }
}

fn tierColor(tier: shared.Item.Tier) dvui.Color {
    return switch (tier) {
        .common => style.rgba(.{ 0.95, 0.95, 0.95, 1 }),
        .uncommon => style.rgba(.{ 0.45, 0.9, 0.35, 1 }),
        .legendary => style.rgba(.{ 0.95, 0.3, 0.25, 1 }),
        .boss => style.rgba(.{ 0.95, 0.85, 0.2, 1 }),
        .equipment => style.rgba(.{ 1, 0.6, 0.15, 1 }),
        .lunar => style.rgba(.{ 0.45, 0.65, 1, 1 }),
    };
}

pub fn wipeMenu(world: *World, network: *Network) Request {
    const is_host = network.host_state == .hosting;
    const button_size: dvui.Size = .{ .w = 260, .h = 44 };
    var panel = style.centeredPanel(@src(), 340, if (is_host) 280 else 228);
    defer panel.deinit();
    style.title(@src(), "Wiped");
    if (is_host and style.button(
        @src(),
        "Go Again",
        0,
        button_size,
        false,
        true,
    )) world.go_again_pending = true;
    if (style.button(@src(), "Exit to Menu", 0, button_size, false, true)) return .main_menu;
    if (style.button(@src(), "Exit to Desktop", 0, button_size, false, true)) return .quit;
    return .none;
}
