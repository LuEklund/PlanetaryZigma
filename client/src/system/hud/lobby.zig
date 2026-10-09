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
    const column_width = std.math.clamp(area.w * 0.3, 260, 420);
    const bottom_height: f32 = 150;
    var request: Request = .none;

    if (survivorGrid(options, .{ .x = margin, .y = margin, .w = column_width, .h = area.h - bottom_height - 2 * margin })) |survivor| request = .{ .lobby = .{ .survivor = survivor } };
    skillPanel(options.survivor, .{ .x = area.w - column_width - margin, .y = margin, .w = column_width, .h = area.h - bottom_height - 2 * margin });
    playerList(world, .{ .x = margin, .y = area.h - bottom_height - margin, .w = column_width, .h = bottom_height });
    if (difficultyPicker(world, is_host, .{ .x = margin * 2 + column_width, .y = area.h - bottom_height - margin, .w = area.w - 2 * column_width - 4 * margin, .h = bottom_height })) |setting| request = .{ .lobby = .{ .difficulty = setting } };

    const ready = if (world.getPtr(world.player_id)) |player| player.ready else false;
    var ready_box = dvui.box(@src(), .{ .dir = .vertical }, .{ .rect = .{ .x = area.w - column_width - margin, .y = area.h - bottom_height - margin, .w = column_width, .h = bottom_height } });
    defer ready_box.deinit();
    if (style.button(@src(), if (ready) "READY  (click to cancel)" else "READY", 0, .{ .w = column_width, .h = 72 }, ready, true)) request = .{ .lobby = .{ .ready = !ready } };
    if (style.button(@src(), "Leave", 0, .{ .w = column_width, .h = 40 }, false, true)) request = .main_menu;
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
    dvui.labelNoFmt(src, text, .{}, .{ .font = style.font(16), .color_text = .fromColor(style.text_dim), .padding = .{ .h = 6 } });
}

fn survivorGrid(options: *Options, rect: dvui.Rect) ?shared.Survivor.Kind {
    var box = panel(@src(), rect);
    defer box.deinit();
    heading(@src(), "SELECT SURVIVOR");
    var picked: ?shared.Survivor.Kind = null;
    for (std.enums.values(shared.Survivor.Kind), 0..) |kind, index| {
        const survivor = shared.Survivor.get(kind);
        if (style.button(@src(), survivor.name, index, .{ .w = rect.w - 28, .h = 56 }, options.survivor == kind, true) and options.survivor != kind) {
            options.survivor = kind;
            picked = kind;
        }
    }
    return picked;
}

fn skillPanel(kind: shared.Survivor.Kind, rect: dvui.Rect) void {
    const survivor = shared.Survivor.get(kind);
    var box = panel(@src(), rect);
    defer box.deinit();
    dvui.labelNoFmt(@src(), survivor.name, .{}, .{ .font = style.font(40), .color_text = .fromColor(style.text) });
    var description = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false, .font = style.font(18), .color_text = .fromColor(style.text_dim), .padding = .{ .h = 12 } });
    description.addText(survivor.description, .{});
    description.deinit();
    dvui.label(@src(), "Health {d:.0}   Damage {d:.1}   Speed {d:.0}", .{ survivor.base_stats.get(.health), survivor.base_stats.get(.damage), survivor.base_stats.get(.speed) }, .{ .font = style.font(16), .color_text = .fromColor(style.accent), .padding = .{ .h = 10 } });

    for (skill_slots, slot_labels, 0..) |slot, slot_label, index| {
        const assigned = survivor.abilities.get(slot) orelse continue;
        const info = shared.skill_info.get(assigned.skill);
        const cooldown_stat: shared.Item.Stat = switch (slot) {
            .primary => .primary_cooldown,
            .secondary => .secondary_cooldown,
            .utility => .utility_cooldown,
            else => .special_cooldown,
        };
        var row = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = index,
            .expand = .horizontal,
            .background = true,
            .color_fill = .fromColor(style.control),
            .margin = .{ .y = 4, .h = 4 },
            .padding = .all(10),
        });
        defer row.deinit();
        dvui.label(@src(), "{s}  -  {d:.1}s", .{ slot_label, survivor.base_stats.get(cooldown_stat) }, .{ .font = style.font(14), .color_text = .fromColor(style.text_dim) });
        dvui.labelNoFmt(@src(), info.name, .{}, .{ .font = style.font(22), .color_text = .fromColor(style.text) });
        var text = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false, .font = style.font(16), .color_text = .fromColor(style.text_dim) });
        text.addText(info.description, .{});
        text.deinit();
    }
}

fn playerList(world: *World, rect: dvui.Rect) void {
    var box = panel(@src(), rect);
    defer box.deinit();
    heading(@src(), "PLAYERS");
    var index: usize = 0;
    for (world.entities.values()) |*entity| {
        if (entity.kind != .player) continue;
        const name = if (entity.player_name.slice().len != 0) entity.player_name.slice() else shared.default_player_name;
        dvui.label(@src(), "{s}  {s}  {s}", .{ if (entity.ready) "[READY]" else "[ ... ]", name, shared.Survivor.get(entity.survivor).name }, .{
            .id_extra = index,
            .font = style.font(18),
            .color_text = .fromColor(if (entity.ready) style.good else style.text),
        });
        index += 1;
    }
}

fn difficultyPicker(world: *World, is_host: bool, rect: dvui.Rect) ?shared.difficulty.Setting {
    var box = panel(@src(), rect);
    defer box.deinit();
    heading(@src(), if (is_host) "DIFFICULTY" else "DIFFICULTY (host picks)");
    var picked: ?shared.difficulty.Setting = null;
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal, .equal_space = true }, .{ .expand = .horizontal });
        defer row.deinit();
        for (std.enums.values(shared.difficulty.Setting), 0..) |setting, index| {
            const selected = world.difficulty_setting == setting;
            if (style.button(@src(), setting.label(), index, .{ .w = 80, .h = 44 }, selected, is_host or selected) and is_host and !selected) picked = setting;
        }
    }
    dvui.labelNoFmt(@src(), world.difficulty_setting.description(), .{}, .{ .font = style.font(16), .color_text = .fromColor(style.text_dim), .padding = .{ .y = 8 } });
    return picked;
}
