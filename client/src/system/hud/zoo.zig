const std = @import("std");
const shared = @import("shared");
const dvui = @import("dvui");
const graphics = @import("graphics");
const zoo = @import("../zoo.zig");
const style = @import("style.zig");
const Models = graphics.Assets.Models;
const ModelRow = graphics.ModelRow;
const World = @import("../../World.zig");

const row_size: dvui.Size = .{ .w = 220, .h = 30 };

pub fn update(state: *const zoo.State, models: *const Models, world: *World) zoo.Command {
    const area = style.screen();
    gridLabels(state, world, area);
    const column_width: f32 = 260;
    var command: zoo.Command = .none;

    {
        var left = panel(@src(), .{ .x = 8, .y = 8, .w = column_width, .h = area.h - 16 });
        defer left.deinit();
        heading(@src(), "Entity");
        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
        defer scroll.deinit();
        for (zoo.kinds, 0..) |kind, index| {
            if (style.button(@src(), ModelRow.kindName(kind), index, row_size, index == state.kind_index, true)) {
                command = .{ .select_kind = @intCast(index) };
            }
        }
        if (style.button(@src(), "Grid view", 0, row_size, state.grid, true)) command = .toggle_grid;
        if (style.button(@src(), "Back (Esc)", 0, row_size, false, true)) command = .exit;
    }

    if (state.grid) return command;
    const kind = zoo.kinds[state.kind_index];
    const handle = models.get(kind);
    const row = models.row(handle) orelse return command;
    const clips = models.modelPtr(handle).clips;
    const assigned = zoo.slotClip(&row, state.slot);

    var right = panel(@src(), .{ .x = area.w - column_width - 8, .y = 8, .w = column_width, .h = area.h - 16 });
    defer right.deinit();
    dvui.labelNoFmt(@src(), row.model, .{}, .{ .font = style.font(16), .color_text = .fromColor(style.text_dim) });
    heading(@src(), "Slot");
    var label_buffer: [128]u8 = undefined;
    var slot_index: usize = 0;
    inline for (.{ shared.entity.Loop, shared.entity.Action }, .{ "loop", "action" }) |Enum, tag| {
        for (std.enums.values(Enum)) |value| {
            const slot = @unionInit(zoo.Slot, tag, value);
            const clip = zoo.slotClip(&row, slot) orelse "-";
            const label = std.fmt.bufPrint(&label_buffer, "{t}: {s}", .{ value, clip }) catch "?";
            const selected = std.meta.eql(slot, state.slot);
            if (style.button(@src(), label, slot_index, row_size, selected, true)) command = .{ .select_slot = slot };
            slot_index += 1;
        }
    }
    if (state.slot == .action) {
        if (style.button(@src(), "Play action", 0, row_size, false, assigned != null)) command = .play_action;
    }
    heading(@src(), "Clip");
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();
    if (style.button(@src(), "(none)", 0, row_size, assigned == null, true)) command = .{ .assign_clip = null };
    for (clips, 0..) |clip, index| {
        const selected = if (assigned) |name| std.mem.eql(u8, name, clip.name) else false;
        if (style.button(@src(), clip.name, index + 1, row_size, selected, true)) {
            command = .{ .assign_clip = @intCast(index) };
        }
    }
    return command;
}

fn gridLabels(state: *const zoo.State, world: *World, area: dvui.Rect) void {
    var buffer: [zoo.max_labels]zoo.Label = undefined;
    const view_proj = world.camera.viewProj(world.options.fov_rad, area.w / area.h);
    for (zoo.labels(world, state, &buffer), 0..) |label, index| {
        const screen = style.worldToScreen(view_proj, label.position) orelse continue;
        dvui.labelNoFmt(@src(), label.name, .{}, .{
            .id_extra = index,
            .rect = .{ .x = screen[0] - 80, .y = screen[1] + 10, .w = 160, .h = 24 },
            .font = style.font(18),
            .color_text = .fromColor(if (label.selected) style.accent else style.text),
            .gravity_x = 0.5,
        });
    }
}

fn panel(src: std.builtin.SourceLocation, rect: dvui.Rect) *dvui.BoxWidget {
    return dvui.box(src, .{ .dir = .vertical }, .{
        .rect = rect,
        .background = true,
        .color_fill = .fromColor(style.panel),
        .padding = .all(8),
    });
}

fn heading(src: std.builtin.SourceLocation, label: []const u8) void {
    dvui.labelNoFmt(src, label, .{}, .{
        .font = style.font(22),
        .color_text = .fromColor(style.accent),
        .padding = .{ .y = 6, .h = 4 },
    });
}
