const Hud = @This();

const std = @import("std");
const nz = @import("shared").numz;
const shared = @import("shared");
const system = @import("../System.zig");
const tracy = @import("ztracy");
const World = system.World;
const Ui = @import("render").Ui;
const Renderer = @import("render").Renderer;
const Window = @import("Window");
const Font = @import("render").Font;
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
    wipe,
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

ui: Ui,

pub fn init(hud: *Hud, gpa: std.mem.Allocator, size: Window.Size, renderer: *Renderer) !void {
    hud.* = .{ .ui = try .init(gpa, size.width, size.height) };
    hud.ui.default_font = &renderer.fonts[0];
    hud.ui.texture_slots = &renderer.texture_slots;
}

pub fn deinit(hud: *Hud, gpa: std.mem.Allocator) void {
    hud.ui.deinit(gpa);
}

pub fn resetScreen(hud: *Hud) void {
    hud.screen = .main;
    hud.overlay = .none;
    hud.options_tab = .gameplay;
    hud.damage_popups = .{};
}

pub const transition_seconds: f32 = 0.12;

pub const crosshair_texture = "textures/crosshair.png";
pub const texture_paths = [_][]const u8{crosshair_texture};

pub fn update(
    hud: *Hud,
    world: *World,
    scene: system.Scene,
    network_manager: *NetworkManager,
    ui: *Ui,
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
    }, world.delta_time);
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
        request = try main_menu.update(world, network_manager, ui, hud, options);
        if (hud.overlay == .options) options_menu.update(ui, hud, options, controller);
    } else {
        try game_hud.update(world, network_manager, ui, options, &hud.damage_popups, controller.show_stats);
        var all_players_dead = world.getPtr(world.player_id) != null;
        for (world.entities.values()) |*entity| {
            if (entity.kind != .player) continue;
            if (!entity.flags.is_dying) all_players_dead = false;
        }
        const wipe_delay = ui.animate("wipe_menu_delay", if (all_players_dead) 1 else 0, 1.0);
        if (all_players_dead and hud.overlay == .none and wipe_delay > 0.85) {
            hud.overlay = .wipe;
        } else if (!all_players_dead and hud.overlay == .wipe) {
            hud.overlay = .none;
        }
        switch (hud.overlay) {
            .none => {},
            .pause => request = try pause_menu.update(ui, hud),
            .wipe => request = game_hud.wipeMenu(world, network_manager, ui),
            .options => options_menu.update(ui, hud, options, controller),
        }
    }
    addTransition(ui, network_manager.phase(), network_manager.elapsed_time - network_manager.host_state_time);

    ui.end();
    return request;
}

fn addTransition(ui: *Ui, phase: NetworkManager.Phase, phase_seconds: f32) void {
    const covering = switch (phase) {
        .starting_server, .waiting_for_server, .connecting => true,
        .idle, .connected => false,
    };
    const transition = ui.animate("transition_veil", if (covering) 1 else 0, transition_seconds);
    if (transition <= 0) return;

    const status_text: []const u8 = if (covering)
        ui.print("{s} {d:.0}s", .{ phase.text(), phase_seconds })
    else
        phase.text();

    ui.add(null, .{
        .name = if (covering) "transition_veil" else null,
        .size = .{ .fixed = .{ .height = ui.screen_height, .width = ui.screen_width } },
        .offset = .{ .left = 0, .top = 0 },
        .color = .new(0, 0, 0, transition),
        .child_anchor = .{ .x = .center, .y = .center },
        .text = .{
            .data = status_text,
            .size = 30,
            .color = .new(0.94, 0.96, 0.9, transition),
        },
    });
}
