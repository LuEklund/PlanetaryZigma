const Hud = @This();

const std = @import("std");
const nz = @import("shared").numz;
const shared = @import("shared");
const system = @import("../system.zig");
const tracy = @import("ztracy");
const Info = system.Info;
const Ui = @import("../Renderer/Vulkan/Ui.zig");
const Resources = @import("../Renderer/Vulkan/Resources.zig");
const NetworkManager = @import("NetworkManager.zig");
const Controller = @import("Controller.zig");
const Options = @import("../Options.zig");

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

pub const crosshair_texture = "textures/crosshair.png";
pub const texture_paths = [_][]const u8{crosshair_texture};

pub fn update(
    hud: *Hud,
    info: *const Info,
    scene: system.Scene,
    network_manager: *NetworkManager,
    ui: *Ui,
    resources: *Resources,
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
    var request: Request = .none;
    if (scene == .menu) {
        request = try main_menu.update(network_manager, ui, hud);
        if (hud.overlay == .options) options_menu.update(ui, hud, options, controller);
    } else {
        try game_hud.update(info, network_manager, ui, resources, options);
        switch (hud.overlay) {
            .none => {},
            .pause => request = try pause_menu.update(ui, hud),
            .options => options_menu.update(ui, hud, options, controller),
        }
    }

    ui.end();
    return request;
}

