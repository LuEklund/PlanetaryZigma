const std = @import("std");
const shared = @import("shared");
const dvui = @import("dvui");
const Hud = @import("../Hud.zig");
const World = @import("../../World.zig");
const Options = @import("../../Options.zig");
const style = @import("style.zig");
const Request = Hud.Request;

pub fn update(hud: *Hud, world: *World, options: *Options, is_host: bool) Request {
    const in_lobby = world.stage == 0;
    const button_size: dvui.Size = .{ .w = 260, .h = 44 };
    const rows: f32 = if (!in_lobby) 3 else if (is_host) 6 else 5;
    style.fillScreen(style.scrim);
    var panel = style.centeredPanel(@src(), 340, 110 + rows * 52);
    defer panel.deinit();
    style.title(@src(), "Paused");

    if (style.button(@src(), "Resume", 0, button_size, false, true)) hud.overlay = .none;
    if (in_lobby) {
        const ready = if (world.getPtr(world.player_id)) |player| player.ready else false;
        var survivor_label: [64]u8 = undefined;
        if (style.button(@src(), std.fmt.bufPrint(&survivor_label, "Survivor: {s}", .{shared.Survivor.get(options.survivor).name}) catch "Survivor", 0, button_size, false, true)) {
            const survivors = std.enums.values(shared.Survivor.Kind);
            options.survivor = survivors[(@intFromEnum(options.survivor) + 1) % survivors.len];
            return .{ .lobby = .{ .survivor = options.survivor } };
        }
        if (style.button(@src(), if (ready) "Ready: YES" else "Ready: no", 0, button_size, ready, true)) return .{ .lobby = .{ .ready = !ready } };
        if (is_host) {
            var difficulty_label: [64]u8 = undefined;
            if (style.button(@src(), std.fmt.bufPrint(&difficulty_label, "Difficulty: {s}", .{world.difficulty_setting.label()}) catch "Difficulty", 0, button_size, false, true)) {
                const settings = std.enums.values(shared.difficulty.Setting);
                return .{ .lobby = .{ .difficulty = settings[(@intFromEnum(world.difficulty_setting) + 1) % settings.len] } };
            }
        }
    }
    if (style.button(@src(), "Options", 0, button_size, false, true)) hud.overlay = .{ .options = .{ .return_to_pause = true } };
    if (style.button(@src(), "Main Menu", 0, button_size, false, true)) return .main_menu;
    return .none;
}
