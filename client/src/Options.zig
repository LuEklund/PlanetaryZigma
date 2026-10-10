const Options = @This();

show_crosshair: bool = true,
mouse_sensitivity: f32 = 2.0,
master_volume: f32 = 1.0,
anti_aliasing: bool = true,
bloom: f32 = 0.5,
invert_y: bool = false,
fullscreen: bool = false,
dev_planet: bool = false,
fov_rad: f32 = 0.65,
chunk_view_distance: f32 = 2,
survivor: @import("shared").Survivor.Kind = .commando,
