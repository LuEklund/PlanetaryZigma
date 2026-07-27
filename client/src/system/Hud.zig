const Hud = @This();

const std = @import("std");
const nz = @import("shared").numz;
const shared = @import("shared");
const system = @import("../System.zig");
const tracy = @import("ztracy");
const Info = system.Info;
const Ui = @import("../Ui.zig");
const Renderer = @import("../Renderer.zig");
const NetworkManager = @import("NetworkManager.zig");
const Controller = @import("Controller.zig");
const Options = @import("../Options.zig");

const DamagePopup = @import("hud/DamagePopup.zig");
const main_menu = @import("hud/main_menu.zig");
const options_menu = @import("hud/options.zig");
const pause_menu = @import("hud/pause.zig");
const game_hud = @import("hud/game.zig");

pub const Screen = enum {
    main,
    multiplayer,
};

pub const OptionsTab = enum {
    gameplay,
    keyboard_mouse,
    video,
    graphics,
};

pub const Overlay = union(enum) {
    none,
    pause,
    options: struct { return_to_pause: bool },
};

pub const Request = union(enum) {
    none,
    main_menu,
    quit,
};

screen: Screen = .main,
overlay: Overlay = .none,
options_tab: OptionsTab = .gameplay,
damage_popups: DamagePopup.List = .{},
popup_prng: std.Random.DefaultPrng = .init(0xD0B0),
transition: f32 = 0,

pub const transition_seconds: f32 = 0.35;

pub const crosshair_texture = "textures/crosshair.png";
pub const texture_paths = [_][]const u8{crosshair_texture};

pub fn update(
    hud: *Hud,
    info: *const Info,
    scene: system.Scene,
    network_manager: *NetworkManager,
    ui: *Ui,
    texture_table: *Renderer.TextureTable,
    controller: *Controller,
    options: *Options,
) !Request {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();

    const position: [2]f32 = .{ @floatCast(controller.mouse_pos[0]), @floatCast(controller.mouse_pos[1]) };
    ui.start(.{
        .position = .{ .left = position[0], .top = position[1] },
        .left_click = controller.mouse_button_left,
        .right_click = controller.mouse_button_right,
    });
    hud.damage_popups.update(info.delta_time);
    if (info.world.getPtr(info.world.player_id)) |player| {
        for (info.world.damage_events.items) |damage_event| {
            if (damage_event.source != info.world.player_id and damage_event.target != info.world.player_id) continue;
            const color: [3]f32 = if (damage_event.delta < 0)
                .{ 0.3, 0.95, 0.35 }
            else if (damage_event.target == info.world.player_id)
                .{ 0.95, 0.25, 0.2 }
            else if (damage_event.delta > player.stats.max.get(.damage))
                .{ 1, 0, 0 }
            else
                .{ 1, 1, 1 };
            hud.damage_popups.spawn(hud.popup_prng.random(), damage_event.position, damage_event.delta, color);
        }
    }
    info.world.damage_events.clearRetainingCapacity();

    var request: Request = .none;
    if (scene == .menu) {
        request = try main_menu.update(info, network_manager, ui, hud, options);
        if (hud.overlay == .options) options_menu.update(ui, hud, options, controller);
    } else {
        try game_hud.update(info, network_manager, ui, texture_table, options, &hud.damage_popups);
        switch (hud.overlay) {
            .none => {},
            .pause => request = try pause_menu.update(ui, hud),
            .options => options_menu.update(ui, hud, options, controller),
        }
    }
    hud.addTransition(ui, info.delta_time, network_manager.phase());

    ui.end();
    return request;
}

/// Added last on purpose: hotUpdate takes the last named node under the cursor,
/// so a full-screen named node IS the input block.
fn addTransition(hud: *Hud, ui: *Ui, delta_time: f32, phase: NetworkManager.Phase) void {
    const covering = switch (phase) {
        .starting_server, .waiting_for_server, .connecting => true,
        .idle, .connected => false,
    };
    const step = delta_time / transition_seconds;
    hud.transition = if (covering)
        @min(1, hud.transition + step)
    else
        @max(0, hud.transition - step);
    if (hud.transition <= 0) return;

    ui.add(null, .{
        .name = if (covering) "transition_veil" else null,
        .size = .{ .fixed = .{ .heigth = ui.screen_heigth, .width = ui.screen_width } },
        .offset = .{ .left = 0, .top = 0 },
        .color = .new(0, 0, 0, hud.transition),
        .child_anchor = .{ .x = .center, .y = .center },
        .text = .{
            .data = phase.text(),
            .size = 30,
            .color = .new(0.94, 0.96, 0.9, hud.transition),
        },
    });
}
