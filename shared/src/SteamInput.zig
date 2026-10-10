//! Steam Input (controllers, Steam Deck) behind plain data: names in, a `Frame` out.
//! The game writes its own action manifest, so no Steamworks partner-site setup is needed.
const SteamInput = @This();

const std = @import("std");
const steam = @import("steamworks");

pub const max_buttons = 64;
pub const action_set_name = "game";
pub const move_action = "move";
pub const look_action = "look";

buttons: [max_buttons]steam.InputDigitalActionHandle_t,
button_count: usize,
move: steam.InputAnalogActionHandle_t,
look: steam.InputAnalogActionHandle_t,
action_set: steam.InputActionSetHandle_t,
started: bool,

pub const Frame = struct {
    connected: bool = false,
    move: [2]f32 = .{ 0, 0 },
    look: [2]f32 = .{ 0, 0 },
    held: std.bit_set.IntegerBitSet(max_buttons) = .initEmpty(),
};

pub const off: SteamInput = .{
    .buttons = @splat(0),
    .button_count = 0,
    .move = 0,
    .look = 0,
    .action_set = 0,
    .started = false,
};

/// Call after SteamAPI_Init. `manifest_path` must be absolute.
pub fn start(manifest_path: [:0]const u8) SteamInput {
    var self: SteamInput = .off;
    const input = steam.SteamInput();
    if (!input.Init(true)) {
        std.log.warn("steam input: init failed, controllers off", .{});
        return self;
    }
    if (!input.SetInputActionManifestFilePath(@ptrCast(manifest_path.ptr))) {
        std.log.warn("steam input: manifest {s} rejected", .{manifest_path});
    }
    self.started = true;
    return self;
}

/// Handles resolve once Steam has parsed the manifest, which can take a few frames.
fn resolve(self: *SteamInput, button_names: []const [:0]const u8) void {
    const input = steam.SteamInput();
    self.action_set = input.GetActionSetHandle(action_set_name);
    if (self.action_set == 0) return;
    std.debug.assert(button_names.len <= max_buttons);
    for (button_names, self.buttons[0..button_names.len]) |name, *handle| {
        handle.* = input.GetDigitalActionHandle(name);
    }
    self.button_count = button_names.len;
    self.move = input.GetAnalogActionHandle(move_action);
    self.look = input.GetAnalogActionHandle(look_action);
    std.log.info("steam input: {d} buttons, move={d} look={d}", .{ button_names.len, self.move, self.look });
}

/// One frame of input from the first connected controller. Button i is `button_names[i]`.
pub fn poll(self: *SteamInput, button_names: []const [:0]const u8) Frame {
    if (!self.started) return .{};
    const input = steam.SteamInput();
    input.RunFrame(false);
    if (self.action_set == 0) self.resolve(button_names);
    if (self.action_set == 0) return .{};

    var controllers: [16]steam.InputHandle_t = undefined;
    const count = input.GetConnectedControllers(&controllers[0]);
    if (count <= 0) return .{};
    const controller = controllers[0];
    input.ActivateActionSet(controller, self.action_set);

    var frame: Frame = .{ .connected = true };
    for (self.buttons[0..self.button_count], 0..) |handle, index| {
        if (input.GetDigitalActionData(controller, handle).bState) frame.held.set(index);
    }
    const move = input.GetAnalogActionData(controller, self.move);
    frame.move = .{ move.x, move.y };
    const look = input.GetAnalogActionData(controller, self.look);
    frame.look = .{ look.x, look.y };
    return frame;
}

/// The In-Game Actions file Steam reads: one action set, a stick for moving,
/// mouse-like look (trackpad/gyro/stick), and one button per name.
pub fn writeManifest(writer: *std.Io.Writer, button_names: []const [:0]const u8, titles: []const []const u8) !void {
    try writer.print(
        \\"Action Manifest"
        \\{{
        \\  "actions"
        \\  {{
        \\    "{s}"
        \\    {{
        \\      "title" "#set_game"
        \\      "StickPadGyro"
        \\      {{
        \\        "{s}" {{ "title" "#action_{s}" "input_mode" "joystick_move" }}
        \\        "{s}" {{ "title" "#action_{s}" "input_mode" "absolute_mouse" }}
        \\      }}
        \\      "Button"
        \\      {{
        \\
    , .{ action_set_name, move_action, move_action, look_action, look_action });
    for (button_names) |name| try writer.print("        \"{s}\" \"#action_{s}\"\n", .{ name, name });
    try writer.print(
        \\      }}
        \\    }}
        \\  }}
        \\  "localization"
        \\  {{
        \\    "english"
        \\    {{
        \\      "set_game" "Game"
        \\      "action_{s}" "Move"
        \\      "action_{s}" "Look"
        \\
    , .{ move_action, look_action });
    for (button_names, titles) |name, title| try writer.print("      \"action_{s}\" \"{s}\"\n", .{ name, title });
    try writer.writeAll(
        \\    }
        \\  }
        \\}
        \\
    );
}
