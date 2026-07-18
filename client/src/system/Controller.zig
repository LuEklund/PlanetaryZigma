const Controller = @This();

const shared = @import("shared");
const yes = @import("yes");

const KeySym = yes.Window.Event.Key.Sym;
const MouseButton = yes.Window.Event.MouseButton.Button;

pub const Action = enum {
    move_forward,
    move_backward,
    move_left,
    move_right,
    jump,
    move_down,
    reload,
    interact,
    attack,
    aim,
    free_camera,
    debug_colliders,
};

pub const bindable_actions = [_]Action{
    .move_forward,
    .move_backward,
    .move_left,
    .move_right,
    .jump,
    .move_down,
    .reload,
    .interact,
    .attack,
    .aim,
    .free_camera,
    .debug_colliders,
};

pub const Binding = union(enum) {
    none,
    key: KeySym,
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

pub const Bindings = struct {
    move_forward: Binding = .{ .key = .w },
    move_backward: Binding = .{ .key = .s },
    move_left: Binding = .{ .key = .a },
    move_right: Binding = .{ .key = .d },
    jump: Binding = .{ .key = .space },
    move_down: Binding = .{ .key = .left_shift },
    reload: Binding = .{ .key = .r },
    interact: Binding = .{ .key = .e },
    attack: Binding = .{ .mouse = .left },
    aim: Binding = .{ .mouse = .right },
    free_camera: Binding = .{ .key = .f1 },
    debug_colliders: Binding = .{ .key = .f2 },

    pub fn get(self: *const Bindings, action: Action) Binding {
        return switch (action) {
            .move_forward => self.move_forward,
            .move_backward => self.move_backward,
            .move_left => self.move_left,
            .move_right => self.move_right,
            .jump => self.jump,
            .move_down => self.move_down,
            .reload => self.reload,
            .interact => self.interact,
            .attack => self.attack,
            .aim => self.aim,
            .free_camera => self.free_camera,
            .debug_colliders => self.debug_colliders,
        };
    }

    pub fn set(self: *Bindings, action: Action, binding: Binding) void {
        switch (action) {
            .move_forward => self.move_forward = binding,
            .move_backward => self.move_backward = binding,
            .move_left => self.move_left = binding,
            .move_right => self.move_right = binding,
            .jump => self.jump = binding,
            .move_down => self.move_down = binding,
            .reload => self.reload = binding,
            .interact => self.interact = binding,
            .attack => self.attack = binding,
            .aim => self.aim = binding,
            .free_camera => self.free_camera = binding,
            .debug_colliders => self.debug_colliders = binding,
        }
    }
};

mouse_pos: [2]f64 = .{ 0, 0 },
mouse_delta: [2]f64 = .{ 0, 0 },
mouse_wheel: f64 = 0,
mouse_button_left: bool = false,
mouse_button_right: bool = false,
input_map: shared.net.Input = .{},
bindings: Bindings = .{},
rebinding_action: ?Action = null,
suppress_escape_release: bool = false,
debug_draw_colliders: bool = false,
free_camera: bool = false,

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

pub fn eventUpdate(self: *Controller, event: *const yes.Window.Event) void {
    switch (event.*) {
        .key => |key| {
            const pressed = key.state == .pressed;
            if (pressed) {
                if (self.rebinding_action) |action| {
                    if (key.sym == .escape) {
                        self.bindings.set(action, .none);
                        self.suppress_escape_release = true;
                    } else {
                        self.bindings.set(action, .{ .key = key.sym });
                    }
                    self.rebinding_action = null;
                    self.clearInput();
                    return;
                }
            }
            if (key.sym == .k) self.input_map.keys.k = pressed;
            for (bindable_actions) |action| {
                if (self.bindings.get(action).eql(.{ .key = key.sym })) {
                    self.applyAction(action, pressed);
                }
            }
        },
        .mouse_scroll => switch (event.mouse_scroll) {
            .vertical => |scroll| self.mouse_wheel = scroll,
            .horizontal => {},
        },
        .focus => |focused| {
            if (!focused) {
                self.clearInput();
                self.releaseMouseButtons();
                self.resetMouseDelta();
                self.rebinding_action = null;
            }
        },
        .mouse_motion => |motion| {
            self.mouse_pos[0] = motion.x;
            self.mouse_pos[1] = motion.y;
            self.mouse_delta[0] += motion.dx;
            self.mouse_delta[1] += motion.dy;
        },
        .mouse_button => |button| {
            const pressed = button.state == .pressed;
            switch (button.button) {
                .left => self.mouse_button_left = pressed,
                .right => self.mouse_button_right = pressed,
                else => {},
            }
            if (pressed) {
                if (self.rebinding_action) |action| {
                    self.bindings.set(action, .{ .mouse = button.button });
                    self.rebinding_action = null;
                    self.clearInput();
                    return;
                }
            }
            for (bindable_actions) |action| {
                if (self.bindings.get(action).eql(.{ .mouse = button.button })) {
                    self.applyAction(action, pressed);
                }
            }
        },

        else => {},
    }
}

fn applyAction(self: *Controller, action: Action, pressed: bool) void {
    switch (action) {
        .move_forward => self.input_map.keys.w = pressed,
        .move_backward => self.input_map.keys.s = pressed,
        .move_left => self.input_map.keys.a = pressed,
        .move_right => self.input_map.keys.d = pressed,
        .jump => self.input_map.keys.space = pressed,
        .move_down => self.input_map.keys.l_shift = pressed,
        .reload => self.input_map.keys.r = pressed,
        .interact => self.input_map.keys.e = pressed,
        .attack => self.input_map.keys.mouse_button_left = pressed,
        .aim => self.input_map.keys.mouse_button_right = pressed,
        .free_camera => {
            if (pressed) self.free_camera = !self.free_camera;
        },
        .debug_colliders => {
            if (pressed) self.debug_draw_colliders = !self.debug_draw_colliders;
        },
    }
}

pub fn actionLabel(action: Action) []const u8 {
    return switch (action) {
        .move_forward => "Move Forward",
        .move_backward => "Move Backward",
        .move_left => "Move Left",
        .move_right => "Move Right",
        .jump => "Jump",
        .move_down => "Move Down",
        .reload => "Reload",
        .interact => "Interact",
        .attack => "Attack",
        .aim => "Aim",
        .free_camera => "Free Camera",
        .debug_colliders => "Debug Colliders",
    };
}

pub fn bindingLabel(binding: Binding) []const u8 {
    return switch (binding) {
        .none => "Unbound",
        .key => |key| keyLabel(key),
        .mouse => |button| mouseLabel(button),
    };
}

fn keyLabel(key: KeySym) []const u8 {
    return switch (key) {
        .w => "W",
        .s => "S",
        .a => "A",
        .d => "D",
        .r => "R",
        .e => "E",
        .k => "K",
        .space => "Space",
        .left_shift => "Left Shift",
        .right_shift => "Right Shift",
        .left_ctrl => "Left Ctrl",
        .right_ctrl => "Right Ctrl",
        .left_alt => "Left Alt",
        .right_alt => "Right Alt",
        .enter => "Enter",
        .tab => "Tab",
        .escape => "Escape",
        .f1 => "F1",
        .f2 => "F2",
        .f3 => "F3",
        .f4 => "F4",
        .f5 => "F5",
        .f6 => "F6",
        .f7 => "F7",
        .f8 => "F8",
        .f9 => "F9",
        .f10 => "F10",
        .f11 => "F11",
        .f12 => "F12",
        else => @tagName(key),
    };
}

fn mouseLabel(button: MouseButton) []const u8 {
    return switch (button) {
        .left => "Mouse Left",
        .right => "Mouse Right",
        .middle => "Mouse Middle",
        .forward => "Mouse Forward",
        .backward => "Mouse Back",
    };
}
