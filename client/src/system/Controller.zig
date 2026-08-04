const Controller = @This();

const std = @import("std");
const shared = @import("shared");

const Window = @import("Window");

pub const MouseButton = std.meta.FieldEnum(Window.Pointer.Buttons);

pub const Action = struct {
    id: @EnumLiteral(),
    default: Binding,
    /// Field of `net.Input.keys` this drives. Actions without one toggle local state
    /// and are handled explicitly in `applyAction`.
    key_field: ?[]const u8 = null,
    /// null means hard-bound: the default stands, and the options menu never lists it.
    bindable: ?Bindable = null,
};

pub const Bindable = struct {
    label: []const u8,
};


pub const Binding = union(enum) {
    none,
    key: Window.Keyboard.Key,
    mouse: MouseButton,

    pub fn eql(self: Binding, other: Binding) bool {
        return switch (self) {
            .none => false,
            .key => |key| switch (other) {
                .key => |other_key| other_key == key,
                else => false,
            },
            .mouse => |button| switch (other) {
                .mouse => |other_button| other_button == button,
                else => false,
            },
        };
    }
};

pub const actions: []const Action = &.{
    .{ .id = .move_forward, .default = .{ .key = .w }, .key_field = "w", .bindable = .{ .label = "Move Forward" } },
    .{ .id = .move_backward, .default = .{ .key = .s }, .key_field = "s", .bindable = .{ .label = "Move Backward" } },
    .{ .id = .move_left, .default = .{ .key = .a }, .key_field = "a", .bindable = .{ .label = "Move Left" } },
    .{ .id = .move_right, .default = .{ .key = .d }, .key_field = "d", .bindable = .{ .label = "Move Right" } },
    .{ .id = .jump, .default = .{ .key = .space }, .key_field = "space", .bindable = .{ .label = "Jump" } },
    .{ .id = .move_down, .default = .{ .key = .left_shift }, .key_field = "l_shift", .bindable = .{ .label = "Move Down" } },
    .{ .id = .reload, .default = .{ .key = .r }, .key_field = "r", .bindable = .{ .label = "Reload" } },
    .{ .id = .interact, .default = .{ .key = .e }, .key_field = "e", .bindable = .{ .label = "Interact" } },
    .{ .id = .attack, .default = .{ .mouse = .left }, .key_field = "mouse_button_left", .bindable = .{ .label = "Attack" } },
    .{ .id = .aim, .default = .{ .mouse = .right }, .key_field = "mouse_button_right", .bindable = .{ .label = "Aim" } },
    .{ .id = .use_equipment, .default = .{ .key = .q }, .key_field = "q", .bindable = .{ .label = "Use Equipment" } },
    .{ .id = .free_camera, .default = .{ .key = .f }, .bindable = .{ .label = "Free Camera" } },
    .{ .id = .debug_colliders, .default = .{ .key = .g }, .bindable = .{ .label = "Debug Colliders" } },
};

pub const Kind = kind: {
    const TagInt = u16;
    var field_names: [actions.len][]const u8 = undefined;
    var field_values: [field_names.len]TagInt = undefined;
    for (actions, &field_names, &field_values, 0..) |action, *name, *value, i| {
        name.* = @tagName(action.id);
        value.* = i;
    }
    break :kind @Enum(TagInt, .exhaustive, &field_names, &field_values);
};

/// `actions` rows carry an `@EnumLiteral()` id, which is comptime-only — so the two
/// fields read at runtime get their own tables.
pub fn get(comptime kind: Kind) Action {
    return actions[@intFromEnum(kind)];
}

pub const bindable: std.EnumArray(Kind, ?Bindable) = table: {
    var bindable_table: std.EnumArray(Kind, ?Bindable) = .initFill(null);
    for (actions, 0..) |action, i| bindable_table.set(@enumFromInt(i), action.bindable);
    break :table bindable_table;
};

pub const Bindings = std.EnumArray(Kind, Binding);

pub const default_bindings: Bindings = bindings: {
    var table: Bindings = .initFill(.none);
    for (actions, 0..) |action, i| table.set(@enumFromInt(i), action.default);
    break :bindings table;
};

mouse_pos: [2]f64 = .{ 0, 0 },
mouse_delta: [2]f64 = .{ 0, 0 },
mouse_wheel: f64 = 0,
mouse_button_left: bool = false,
mouse_button_right: bool = false,
previous_buttons: Window.Pointer.Buttons = .{},
input_map: shared.net.Input = .{},
bindings: Bindings = default_bindings,
rebinding_action: ?Kind = null,
suppress_escape_release: bool = false,
debug_draw_colliders: bool = false,
free_camera: bool = false,
show_stats: bool = false,

pub fn clearInput(self: *Controller) void {
    self.input_map = .{};
    self.mouse_wheel = 0;
}

pub fn releaseMouseButtons(self: *Controller) void {
    self.mouse_button_left = false;
    self.mouse_button_right = false;
}

pub fn resetMouseDelta(self: *Controller) void {
    self.mouse_delta = .{ 0, 0 };
}

fn buttonDown(buttons: Window.Pointer.Buttons, button: MouseButton) bool {
    return switch (button) {
        inline else => |b| @field(buttons, @tagName(b)),
    };
}

pub fn update(self: *Controller, window: *const Window) void {
    if (!window.focused) {
        self.clearInput();
        self.releaseMouseButtons();
        self.resetMouseDelta();
        self.rebinding_action = null;
        self.previous_buttons = .{};
        return;
    }

    const keyboard = window.keyboard;
    const buttons = window.pointer.buttons;
    defer self.previous_buttons = buttons;

    if (self.rebinding_action) |action| {
        std.debug.assert(bindable.get(action) != null);
        for (std.enums.values(Window.Keyboard.Key)) |key| {
            if (keyboard.get(key) != .press) continue;
            if (key == .escape) {
                self.bindings.set(action, .none);
                self.suppress_escape_release = true;
            } else {
                self.bindings.set(action, .{ .key = key });
            }
            self.rebinding_action = null;
            self.clearInput();
            return;
        }
        for (std.enums.values(MouseButton)) |button| {
            if (!buttonDown(buttons, button) or buttonDown(self.previous_buttons, button)) continue;
            self.bindings.set(action, .{ .mouse = button });
            self.rebinding_action = null;
            self.clearInput();
            return;
        }
        return;
    }

    self.show_stats = keyboard.isDown(.tab);

    if (keyboard.get(.f1) == .press) self.input_map.dev_command = .f1;
    if (keyboard.get(.f2) == .press) self.input_map.dev_command = .f2;
    if (keyboard.get(.f3) == .press) self.input_map.dev_command = .f3;
    if (keyboard.get(.f4) == .press) self.input_map.dev_command = .f4;
    if (keyboard.get(.f5) == .press) self.input_map.dev_command = .f5;
    if (keyboard.get(.f6) == .press) self.input_map.dev_command = .f6;
    if (keyboard.get(.f7) == .press) self.input_map.dev_command = .f7;
    if (keyboard.get(.f8) == .press) self.input_map.dev_command = .f8;
    if (keyboard.get(.f9) == .press) self.input_map.dev_command = .f9;
    if (keyboard.get(.f10) == .press) self.input_map.dev_command = .f10;
    if (keyboard.get(.f11) == .press) self.input_map.dev_command = .f11;
    if (keyboard.get(.f12) == .press) self.input_map.dev_command = .f12;

    for (std.enums.values(Kind)) |action| {
        switch (self.bindings.get(action)) {
            .none => {},
            .key => |key| switch (keyboard.get(key)) {
                .press => self.applyAction(action, true),
                .release => self.applyAction(action, false),
                .none, .repeat => {},
            },
            .mouse => |button| {
                const down = buttonDown(buttons, button);
                if (down != buttonDown(self.previous_buttons, button)) self.applyAction(action, down);
            },
        }
    }

    self.mouse_button_left = buttons.left;
    self.mouse_button_right = buttons.right;

    switch (window.pointer.movement) {
        .position => |position| self.mouse_pos = .{ position.x, position.y },
        .relative => |relative| {
            self.mouse_delta[0] += relative.dx;
            self.mouse_delta[1] += relative.dy;
        },
    }
    self.mouse_wheel = window.pointer.axis.vertical;
}

fn applyAction(self: *Controller, action: Kind, pressed: bool) void {
    switch (action) {
        .free_camera => if (pressed) {
            self.free_camera = !self.free_camera;
        },
        .debug_colliders => if (pressed) {
            self.debug_draw_colliders = !self.debug_draw_colliders;
        },
        inline else => |inline_action| @field(self.input_map.keys, get(inline_action).key_field.?) = pressed,
    }
}

pub fn bindingLabel(binding: Binding) []const u8 {
    return switch (binding) {
        .none => "Unbound",
        .key => |key| switch (key) {
            inline else => |inline_key| comptime titleCase(@tagName(inline_key)),
        },
        .mouse => |button| switch (button) {
            inline else => |inline_button| "Mouse " ++ comptime titleCase(@tagName(inline_button)),
        },
    };
}

fn titleCase(comptime tag: []const u8) []const u8 {
    @setEvalBranchQuota(10_000);
    var text: [tag.len]u8 = undefined;
    var start_of_word = true;
    for (tag, &text) |char, *out| {
        if (char == '_') {
            out.* = ' ';
            start_of_word = true;
            continue;
        }
        out.* = if (start_of_word) std.ascii.toUpper(char) else char;
        start_of_word = false;
    }
    const final = text;
    return &final;
}

