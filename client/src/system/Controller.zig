const Controller = @This();

const std = @import("std");
const shared = @import("shared");

const Window = @import("Window");

pub const Action = struct {
    id: @EnumLiteral(),
    default: Binding,
    bindable: ?[]const u8 = null,
};

pub const Binding = union(enum) {
    none,
    key: Window.Keyboard.Key,
    mouse: Window.Pointer.Buttons,

    // pub fn eql(self: Binding, other: Binding) bool {
    //     return switch (self) {
    //         .none => false,
    //         .key => |key| switch (other) {
    //             .key => |other_key| other_key == key,
    //             else => false,
    //         },
    //         .mouse => |button| switch (other) {
    //             .mouse => |other_button| other_button == button,
    //             else => false,
    //         },
    //     };
    // }
};

pub const actions: []const Action = &.{
    .{ .id = .move_forward, .default = .{ .key = .w }, .bindable = "Move Forward" },
    .{ .id = .move_backward, .default = .{ .key = .s }, .bindable = "Move Backward" },
    .{ .id = .move_left, .default = .{ .key = .a }, .bindable = "Move Left" },
    .{ .id = .move_right, .default = .{ .key = .d }, .bindable = "Move Right" },
    .{ .id = .jump, .default = .{ .key = .space }, .bindable = "Jump" },
    .{ .id = .move_down, .default = .{ .key = .left_shift }, .bindable = "Move Down" },
    .{ .id = .reload, .default = .{ .key = .r }, .bindable = "Reload" },
    .{ .id = .interact, .default = .{ .key = .e }, .bindable = "Interact" },
    .{ .id = .attack, .default = .{ .mouse = .{ .left = true } }, .bindable = "Attack" },
    .{ .id = .aim, .default = .{ .mouse = .{ .right = true } }, .bindable = "Aim" },
    .{ .id = .use_equipment, .default = .{ .key = .q }, .bindable = "Use Equipment" },
    .{ .id = .free_camera, .default = .{ .key = .f }, .bindable = "Free Camera" },
    .{ .id = .debug_colliders, .default = .{ .key = .g }, .bindable = "Debug Colliders" },
    .{ .id = .utility, .default = .{ .key = .left_shift }, .bindable = "Utility" },
    .{ .id = .secondary, .default = .{ .mouse = .{ .right = true } }, .bindable = "Secondary" },
    .{ .id = .dev_f1, .default = .{ .key = .f1 } },
    .{ .id = .dev_f2, .default = .{ .key = .f2 } },
    .{ .id = .dev_f3, .default = .{ .key = .f3 } },
    .{ .id = .dev_f4, .default = .{ .key = .f4 } },
    .{ .id = .dev_f5, .default = .{ .key = .f5 } },
    .{ .id = .dev_f6, .default = .{ .key = .f6 } },
    .{ .id = .dev_f7, .default = .{ .key = .f7 } },
    .{ .id = .dev_f8, .default = .{ .key = .f8 } },
    .{ .id = .dev_f9, .default = .{ .key = .f9 } },
    .{ .id = .dev_f10, .default = .{ .key = .f10 } },
    .{ .id = .dev_f11, .default = .{ .key = .f11 } },
    .{ .id = .dev_f12, .default = .{ .key = .f12 } },
};

pub const ActionKind = kind: {
    const TagInt = u16;
    var field_names: [actions.len][]const u8 = undefined;
    var field_values: [field_names.len]TagInt = undefined;
    for (actions, &field_names, &field_values, 0..) |action, *name, *value, i| {
        name.* = @tagName(action.id);
        value.* = i;
    }
    break :kind @Enum(TagInt, .exhaustive, &field_names, &field_values);
};

pub const bindable: std.EnumArray(ActionKind, ?[]const u8) = table: {
    var bindable_table: std.EnumArray(ActionKind, ?[]const u8) = .initFill(null);
    for (actions, 0..) |action, i| bindable_table.set(@enumFromInt(i), action.bindable);
    break :table bindable_table;
};

pub const Bindings = std.EnumArray(ActionKind, Binding);

pub const default_bindings: Bindings = bindings: {
    var table: Bindings = .initFill(.none);
    for (actions, 0..) |action, i| table.set(@enumFromInt(i), action.default);
    break :bindings table;
};

// mouse_button_left: bool = false,
// mouse_button_right: bool = false,
bindings: Bindings = default_bindings,
rebinding_action: ?ActionKind = null,
debug_draw_colliders: bool = false,
free_camera: bool = false,
cooldown: std.EnumArray(shared.entity.Action, f32) = .initFill(0),

pub fn update(self: *Controller, window: *const Window) shared.net.Input {
    // if (!window.focused) {
    //     self.clearInput();
    //     self.releaseMouseButtons();
    //     self.resetMouseDelta();
    //     self.rebinding_action = null;
    //     self.previous_buttons = .{};
    //     return .{};
    // }

    var new_player_inputs: shared.net.Input = .{};

    // const keyboard = window.keyboard;
    // const buttons = window.pointer.buttons;
    // defer self.previous_buttons = buttons;

    // if (self.rebinding_action) |action| {
    //     std.debug.assert(bindable.get(action) != null);
    //     for (std.enums.values(Window.Keyboard.Key)) |key| {
    //         if (keyboard.get(key) != .press) continue;
    //         if (key == .escape) {
    //             self.bindings.set(action, .none);
    //             self.suppress_escape_release = true;
    //         } else {
    //             self.bindings.set(action, .{ .key = key });
    //         }
    //         self.rebinding_action = null;
    //         self.clearInput();
    //         return .{};
    //     }
    //     for (std.enums.values(MouseButton)) |button| {
    //         if (!mouseButtonDown(buttons, button) or mouseButtonDown(self.previous_buttons, button)) continue;
    //         self.bindings.set(action, .{ .mouse = button });
    //         self.rebinding_action = null;
    //         self.clearInput();
    //         return .{};
    //     }
    //     return .{};
    // }

    // self.show_stats = keyboard.isDown(.tab);

    for (std.enums.values(ActionKind)) |action| {
        switch (self.bindings.get(action)) {
            .none => {},
            .key => |key| applyAction(&new_player_inputs, action, window.keyboard.get(key).isDown()),
            .mouse => |mask| applyAction(
                &new_player_inputs,
                action,
                @as(u8, @bitCast(window.pointer.buttons)) & @as(u8, @bitCast(mask)) != 0,
            ),
        }
    }

    // self.mouse_button_left = buttons.left;
    // self.mouse_button_right = buttons.right;

    return new_player_inputs;
}

fn applyAction(inputs: *shared.net.Input, action: ActionKind, pressed: bool) void {
    switch (action) {
        inline else => |inline_action| {
            const Keys = @FieldType(shared.net.Input, "keys");
            if (@hasField(Keys, @tagName(inline_action))) @field(inputs.keys, @tagName(inline_action)) = pressed;
        },
    }
}

// fn mouseButtonDown(buttons: Window.Pointer.Buttons, button: MouseButton) bool {
//     return switch (button) {
//         inline else => |b| @field(buttons, @tagName(b)),
//     };
// }

// pub fn bindingLabel(binding: Binding) []const u8 {
//     return switch (binding) {
//         .none => "Unbound",
//         .key => |key| switch (key) {
//             inline else => |inline_key| comptime titleCase(@tagName(inline_key)),
//         },
//         .mouse => |button| switch (button) {
//             inline else => |inline_button| "Mouse " ++ comptime titleCase(@tagName(inline_button)),
//         },
//     };
// }

// fn titleCase(comptime tag: []const u8) []const u8 {
//     @setEvalBranchQuota(10_000);
//     var text: [tag.len]u8 = undefined;
//     var start_of_word = true;
//     for (tag, &text) |char, *out| {
//         if (char == '_') {
//             out.* = ' ';
//             start_of_word = true;
//             continue;
//         }
//         out.* = if (start_of_word) std.ascii.toUpper(char) else char;
//         start_of_word = false;
//     }
//     const final = text;
//     return &final;
// }
