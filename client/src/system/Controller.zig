const shared = @import("shared");
const tracy = @import("ztracy");
const yes = @import("yes");

mouse_pos: [2]f64 = .{ 0, 0 },
mouse_prev_pos: [2]f64 = .{ 0, 0 },
mouse_delta: [2]f64 = .{ 0, 0 },
mouse_wheel: f64 = 0,
input_map: shared.net.Input = .{},
debug_draw_colliders: bool = false,
f1_held: bool = false,
free_camera: bool = false,
f2_held: bool = false,

pub fn update(self: *@This()) void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();

    self.mouse_delta[0] = self.mouse_pos[0] - self.mouse_prev_pos[0];
    self.mouse_delta[1] = self.mouse_pos[1] - self.mouse_prev_pos[1];
    self.mouse_prev_pos[0] = self.mouse_pos[0];
    self.mouse_prev_pos[1] = self.mouse_pos[1];
}

pub fn eventUpdate(self: *@This(), event: *const yes.Window.Event) void {
    switch (event.*) {
        .key => |key| {
            const pressed = key.state == .pressed;
            switch (key.sym) {
                .w => self.input_map.keys.w = pressed,
                .s => self.input_map.keys.s = pressed,
                .d => self.input_map.keys.d = pressed,
                .a => self.input_map.keys.a = pressed,
                .left_shift => self.input_map.keys.l_shift = pressed,
                .space => self.input_map.keys.space = pressed,
                .r => self.input_map.keys.r = pressed,
                .k => self.input_map.keys.k = pressed,
                .e => self.input_map.keys.e = pressed,
                .f1 => {
                    if (pressed and !self.f1_held) self.debug_draw_colliders = !self.debug_draw_colliders;
                    self.f1_held = pressed;
                },
                .f2 => {
                    if (pressed and !self.f2_held) self.free_camera = !self.free_camera;
                    self.f2_held = pressed;
                },
                else => {},
            }
        },
        .mouse_scroll => switch (event.mouse_scroll) {
            .vertical => |scroll| {
                self.mouse_wheel = scroll;
            },
            .horizontal => {},
        },
        .focus => |focused| {
            if (!focused) {
                self.input_map = .{};
                self.mouse_wheel = 0;
            }
        },
        .mouse_motion => |motion| {
            self.mouse_pos[0] = motion.x;
            self.mouse_pos[1] = motion.y;
        },
        .mouse_button => |button| {
            if (button.state == .pressed and button.button == .left)
                self.input_map.keys.mouse_button_left = true
            else if (button.state == .released and button.button == .left) {
                self.input_map.keys.mouse_button_left = false;
            }
            if (button.state == .pressed and button.button == .right)
                self.input_map.keys.mouse_button_right = true
            else if (button.state == .released and button.button == .right) {
                self.input_map.keys.mouse_button_right = false;
            }
        },

        else => {},
    }
}
