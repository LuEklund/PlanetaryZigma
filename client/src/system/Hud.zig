const Hud = @This();

const std = @import("std");
const shared = @import("shared");
const dvui = @import("dvui");
const system = @import("../System.zig");
const tracy = @import("ztracy");
const World = system.World;
const Assets = @import("graphics").Assets;
const NetworkManager = @import("NetworkManager.zig");
const Options = @import("../Options.zig");
const style = @import("hud/style.zig");

const DamagePopup = @import("hud/DamagePopup.zig");
const main_menu = @import("hud/main_menu.zig");
const options_menu = @import("hud/options.zig");
const pause_menu = @import("hud/pause.zig");
const game_hud = @import("hud/game.zig");
const lobby_screen = @import("hud/lobby.zig");

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
    wipe,
    options: struct { return_to_pause: bool },
};

pub const Request = union(enum) {
    none,
    main_menu,
    quit,
    lobby: shared.net.LobbyCommand,
};

screen: Screen,
overlay: Overlay,
options_tab: OptionsTab,
damage_popups: DamagePopup.List,
popup_prng: std.Random.DefaultPrng,
veil: f32,
wipe_delay: f32,
death_fade: f32,

pub const init: Hud = .{
    .screen = .main,
    .overlay = .none,
    .options_tab = .gameplay,
    .damage_popups = .empty,
    .popup_prng = .init(0xD0B0),
    .veil = 0,
    .wipe_delay = 0,
    .death_fade = 0,
};

pub fn resetScreen(hud: *Hud) void {
    hud.screen = .main;
    hud.overlay = .none;
    hud.options_tab = .gameplay;
    hud.damage_popups = .empty;
    hud.wipe_delay = 0;
    hud.death_fade = 0;
}

pub const transition_seconds: f32 = 0.12;

pub const crosshair_texture = "textures/crosshair.png";
pub const texture_paths = [_][]const u8{crosshair_texture};

pub fn approach(value: f32, target: f32, delta_time: f32, seconds: f32) f32 {
    const step = delta_time / @max(seconds, 0.0001);
    return if (value < target) @min(target, value + step) else @max(target, value - step);
}

pub fn update(
    hud: *Hud,
    world: *World,
    scene: system.Scene,
    network_manager: *NetworkManager,
    options: *Options,
    game_assets: *const Assets,
) !Request {
    const controller = &world.controller;
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();

    hud.damage_popups.update(world.delta_time);
    if (world.getPtr(world.player_id)) |player| {
        for (world.damage_events.items) |damage_event| {
            if (damage_event.source != world.player_id and damage_event.target != world.player_id) continue;
            const color: [3]f32 = if (damage_event.delta < 0)
                .{ 0.3, 0.95, 0.35 }
            else if (damage_event.target == world.player_id)
                .{ 0.95, 0.25, 0.2 }
            else if (damage_event.delta > player.stat(.damage))
                .{ 1, 0, 0 }
            else
                .{ 1, 1, 1 };
            hud.damage_popups.spawn(hud.popup_prng.random(), damage_event.position, damage_event.delta, color);
        }
    }
    world.damage_events.clearRetainingCapacity();

    var request: Request = .none;
    if (scene == .menu) {
        request = try main_menu.update(network_manager, hud, options);
        if (hud.overlay == .options) options_menu.update(hud, options, controller);
    } else {
        const is_host = network_manager.host_state == .hosting;
        if (world.stage == 0) {
            if (hud.overlay == .none) request = lobby_screen.update(world, options, is_host);
        } else {
            game_hud.update(hud, world, network_manager, options, game_assets);
        }
        var all_players_dead = world.getPtr(world.player_id) != null;
        for (world.entities.values()) |*entity| {
            if (entity.kind != .player) continue;
            if (entity.health > 0) all_players_dead = false;
        }
        hud.wipe_delay = approach(hud.wipe_delay, if (all_players_dead) 1 else 0, world.delta_time, 1.0);
        if (all_players_dead and hud.overlay == .none and hud.wipe_delay > 0.85) {
            hud.overlay = .wipe;
        } else if (!all_players_dead and hud.overlay == .wipe) {
            hud.overlay = .none;
        }
        switch (hud.overlay) {
            .none => {},
            .pause => request = pause_menu.update(hud),
            .wipe => request = game_hud.wipeMenu(world, network_manager),
            .options => options_menu.update(hud, options, controller),
        }
    }
    hud.addTransition(network_manager.phase(), network_manager.elapsed_time - network_manager.host_state_time, world.delta_time);
    return request;
}

fn addTransition(hud: *Hud, phase: NetworkManager.Phase, phase_seconds: f32, delta_time: f32) void {
    const covering = switch (phase) {
        .starting_server, .waiting_for_server, .connecting => true,
        .idle, .connected => false,
    };
    hud.veil = approach(hud.veil, if (covering) 1 else 0, delta_time, transition_seconds);
    if (hud.veil <= 0) return;

    style.fillScreen(style.rgba(.{ 0, 0, 0, hud.veil }));
    const label_options: dvui.Options = .{
        .font = style.font(30),
        .color_text = .fromColor(style.text.opacity(hud.veil)),
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .rect = style.screen(),
    };
    if (covering) {
        dvui.label(@src(), "{s} {d:.0}s", .{ phase.text(), phase_seconds }, label_options);
    } else {
        dvui.labelNoFmt(@src(), phase.text(), .{}, label_options);
    }
}
