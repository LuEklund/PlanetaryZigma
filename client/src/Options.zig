const Options = @This();

show_hud_stats: bool = true,
show_crosshair: bool = true,
mouse_sensitivity: f32 = 1.0,
invert_y: bool = false,
fullscreen: bool = false,
fov_rad: f32 = 1.5,

pub fn cycleMouseSensitivity(options: *Options) void {
    const values = [_]f32{ 0.5, 0.75, 1.0, 1.25, 1.5, 2.0 };
    options.mouse_sensitivity = cycleF32(values, options.mouse_sensitivity);
}

pub fn cycleFov(options: *Options) void {
    const values = [_]f32{ 1.2, 1.35, 1.5, 1.65, 1.8 };
    options.fov_rad = cycleF32(values, options.fov_rad);
}

fn cycleF32(comptime values: anytype, current: f32) f32 {
    for (values, 0..) |value, i| {
        if (@abs(value - current) < 0.001) return values[(i + 1) % values.len];
    }
    return values[0];
}
