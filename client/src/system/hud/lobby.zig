const std = @import("std");
const shared = @import("shared");
const dvui = @import("dvui");
const World = @import("../../World.zig");
const Options = @import("../../Options.zig");
const Hud = @import("../Hud.zig");
const style = @import("style.zig");
const Request = Hud.Request;

const margin: f32 = 24;
const skill_slots = [_]shared.entity.Action{ .primary, .secondary, .utility, .special };
const slot_labels = [_][]const u8{ "Primary", "Secondary", "Utility", "Special" };

pub fn update(world: *World, options: *Options, is_host: bool) Request {
    const area = style.screen();
    const column_width = std.math.clamp(area.w * 0.3, 280, 460);
    const bottom_height: f32 = 140;
    const column_height = area.h - bottom_height - 3 * margin;
    var request: Request = .none;

    if (survivorColumn(
        options,
        .{ .x = margin, .y = margin, .w = column_width, .h = column_height },
    )) |survivor| {
        request = .{ .lobby = .{ .survivor = survivor } };
    }
    const right: dvui.Rect = .{
        .x = area.w - column_width - margin,
        .y = margin,
        .w = column_width,
        .h = column_height,
    };
    if (infoColumn(world, is_host, right)) |setting| request = .{
        .lobby = .{ .difficulty = setting },
    };
    playerList(
        world,
        .{
            .x = margin,
            .y = area.h - bottom_height - margin,
            .w = column_width,
            .h = bottom_height,
        },
    );

    const ready = if (world.getPtr(world.player_id)) |player| player.ready else false;
    var ready_box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .rect = .{
            .x = right.x,
            .y = area.h - bottom_height - margin,
            .w = column_width,
            .h = bottom_height,
        },
    });
    defer ready_box.deinit();
    const ready_label = if (ready) "READY  (click to cancel)" else "READY";
    if (style.button(@src(), ready_label, 0, .{ .w = column_width, .h = 72 }, ready, true)) {
        request = .{ .lobby = .{ .ready = !ready } };
    }
    if (style.button(
        @src(),
        "Leave",
        0,
        .{ .w = column_width, .h = 40 },
        false,
        true,
    )) request = .main_menu;
    return request;
}

fn panel(src: std.builtin.SourceLocation, rect: dvui.Rect) *dvui.BoxWidget {
    return dvui.box(src, .{ .dir = .vertical }, .{
        .rect = rect,
        .background = true,
        .color_fill = .fromColor(style.panel),
        .padding = .all(14),
    });
}

fn heading(src: std.builtin.SourceLocation, text: []const u8) void {
    dvui.labelNoFmt(
        src,
        text,
        .{},
        .{
            .font = style.font(16),
            .color_text = .fromColor(style.text_dim),
            .padding = .{ .h = 6 },
        },
    );
}

fn survivorColumn(options: *Options, rect: dvui.Rect) ?shared.Survivor.Kind {
    var box = panel(@src(), rect);
    defer box.deinit();
    heading(@src(), "SELECT SURVIVOR");
    var picked: ?shared.Survivor.Kind = null;
    for (std.enums.values(shared.Survivor.Kind), 0..) |kind, index| {
        const selected = options.survivor == kind;
        const name = shared.Survivor.get(kind).name;
        if (style.button(
            @src(),
            name,
            index,
            .{ .w = rect.w - 28, .h = 44 },
            selected,
            true,
        ) and !selected) {
            options.survivor = kind;
            picked = kind;
        }
    }
    overview(shared.Survivor.get(options.survivor));
    heading(@src(), "ABILITIES");
    abilityList(shared.Survivor.get(options.survivor));
    return picked;
}

fn overview(survivor: *const shared.Survivor) void {
    dvui.labelNoFmt(
        @src(),
        survivor.name,
        .{},
        .{ .font = style.font(36), .color_text = .fromColor(style.text), .padding = .{ .y = 10 } },
    );
    style.wrapped(@src(), survivor.description, 17, style.text_dim);
    var stats_buffer: [96]u8 = undefined;
    const stats = std.fmt.bufPrint(&stats_buffer, "Health {d:.0}   Base Damage {d:.1}   Speed {d:.0}", .{
        survivor.base_stats.get(.health),
        survivor.base_stats.get(.damage),
        survivor.base_stats.get(.speed),
    }) catch "";
    style.wrapped(@src(), stats, 16, style.accent);
}

fn abilityList(survivor: *const shared.Survivor) void {
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();
    for (skill_slots, slot_labels, 0..) |slot, slot_label, index| {
        const assigned = survivor.abilities.get(slot) orelse continue;
        const info = shared.skill_info.get(assigned.skill);
        var row = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = index,
            .expand = .horizontal,
            .background = true,
            .color_fill = .fromColor(style.control),
            .margin = .{ .y = 3, .h = 3 },
            .padding = .all(10),
        });
        defer row.deinit();
        dvui.labelNoFmt(
            @src(),
            info.name,
            .{},
            .{ .font = style.font(22), .color_text = .fromColor(style.text) },
        );
        var line_buffer: [96]u8 = undefined;
        const line = abilityLine(
            &line_buffer,
            slot_label,
            survivor.base_stats.get(cooldownStat(slot)),
            assigned,
            info,
        );
        dvui.labelNoFmt(
            @src(),
            line,
            .{},
            .{ .font = style.font(15), .color_text = .fromColor(style.accent) },
        );
        style.wrapped(@src(), info.description, 16, style.text_dim);
    }
}

fn abilityLine(
    buffer: []u8,
    slot_label: []const u8,
    cooldown: f32,
    assigned: shared.entity.AssignedSkill,
    info: shared.skill_info.Info,
) []const u8 {
    const percent = assigned.damage_multiplier * 100;
    return switch (info.effect) {
        .damage => if (assigned.hits > 1)
            std.fmt.bufPrint(
                buffer,
                "{s} - {d:.1}s - {d}x{d:.0}% base damage",
                .{ slot_label, cooldown, assigned.hits, percent },
            )
        else
            std.fmt.bufPrint(
                buffer,
                "{s} - {d:.1}s - {d:.0}% base damage",
                .{ slot_label, cooldown, percent },
            ),
        .heal => std.fmt.bufPrint(
            buffer,
            "{s} - {d:.1}s - heals {d:.0}% max health",
            .{ slot_label, cooldown, percent },
        ),
        .none => std.fmt.bufPrint(buffer, "{s} - {d:.1}s", .{ slot_label, cooldown }),
    } catch slot_label;
}

fn cooldownStat(slot: shared.entity.Action) shared.Item.Stat {
    return switch (slot) {
        .primary => .primary_cooldown,
        .secondary => .secondary_cooldown,
        .utility => .utility_cooldown,
        else => .special_cooldown,
    };
}

fn infoColumn(world: *World, is_host: bool, rect: dvui.Rect) ?shared.difficulty.Setting {
    var box = panel(@src(), rect);
    defer box.deinit();
    return difficultyPicker(world, is_host);
}

fn playerList(world: *World, rect: dvui.Rect) void {
    var box = panel(@src(), rect);
    defer box.deinit();
    heading(@src(), "PLAYERS");
    var index: usize = 0;
    for (world.entities.values()) |*entity| {
        if (entity.kind != .player) continue;
        const name = if (entity.player_name.slice().len != 0) entity.player_name.slice() else shared.default_player_name;
        dvui.label(@src(), "{s}  {s}  {s}", .{
            if (entity.ready) "[READY]" else "[ ... ]",
            name,
            shared.Survivor.get(entity.survivor).name,
        }, .{
            .id_extra = index,
            .font = style.font(18),
            .color_text = .fromColor(if (entity.ready) style.good else style.text),
        });
        index += 1;
    }
}

fn difficultyPicker(world: *World, is_host: bool) ?shared.difficulty.Setting {
    heading(@src(), if (is_host) "DIFFICULTY" else "DIFFICULTY (host picks)");
    var picked: ?shared.difficulty.Setting = null;
    for (std.enums.values(shared.difficulty.Setting), 0..) |setting, index| {
        const selected = world.difficulty_setting == setting;
        const enabled = is_host or selected;
        if (style.button(
            @src(),
            setting.label(),
            index,
            .{ .w = 80, .h = 44 },
            selected,
            enabled,
        ) and is_host and !selected) {
            picked = setting;
        }
    }
    style.wrapped(@src(), world.difficulty_setting.description(), 16, style.text_dim);
    return picked;
}
