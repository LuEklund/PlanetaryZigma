const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const Camera = @import("system/Camera.zig");
const Controller = @import("system/Controller.zig");

pub const max_entities: usize = 1024;

pub const MenuScreen = enum {
    main,
    multiplayer,
};

pub const OptionsTab = enum {
    gameplay,
    keyboard_mouse,
    controller,
    audio,
    video,
    graphics,
};

pub const Options = struct {
    tab: OptionsTab = .gameplay,
    auto_sprint: bool = false,
    show_hud_stats: bool = true,
    show_crosshair: bool = true,
    mouse_sensitivity: f32 = 1.0,
    invert_y: bool = false,
    controller_enabled: bool = false,
    controller_vibration: bool = true,
    master_volume: u8 = 100,
    fullscreen: bool = false,
    fov_rad: f32 = 1.5,

    pub fn cycleMouseSensitivity(self: *Options) void {
        const values = [_]f32{ 0.5, 0.75, 1.0, 1.25, 1.5, 2.0 };
        self.mouse_sensitivity = cycleF32(values, self.mouse_sensitivity);
    }

    pub fn cycleMasterVolume(self: *Options) void {
        const values = [_]u8{ 0, 25, 50, 75, 100 };
        self.master_volume = cycleU8(values, self.master_volume);
    }

    pub fn cycleFov(self: *Options) void {
        const values = [_]f32{ 1.2, 1.35, 1.5, 1.65, 1.8 };
        self.fov_rad = cycleF32(values, self.fov_rad);
    }

    fn cycleF32(comptime values: anytype, current: f32) f32 {
        for (values, 0..) |value, i| {
            if (@abs(value - current) < 0.001) return values[(i + 1) % values.len];
        }
        return values[0];
    }

    fn cycleU8(comptime values: anytype, current: u8) u8 {
        for (values, 0..) |value, i| {
            if (value == current) return values[(i + 1) % values.len];
        }
        return values[0];
    }
};

pub const MenuTuning = struct {
    camera_target: nz.Vec3(f32) = .{ 6, -5, -45 },
    camera_yaw: f32 = -0.35,
    camera_pitch: f32 = -0.22,
    camera_distance: f32 = 50,
    fov_rad: f32 = 1.25,
    planet_position: nz.Vec3(f32) = .{ 6, -16, -52 },
    planet_scale: f32 = 0.75,
    bozo_screen: [2]f32 = .{ 0.53, 0.49 },
    bozo_surface_offset: f32 = 3.5,
    player_scale: f32 = 4.4,
};

mutex: std.Io.Mutex = .init,
gpa: std.mem.Allocator,
entities: std.AutoArrayHashMapUnmanaged(shared.entity.Id, Entity) = .empty,
teleporter_bosses: std.ArrayList(shared.entity.Id) = .empty,
pending_spawn: std.ArrayList(shared.net.SpawnEntity) = .empty,
pending_despawn: std.ArrayList(shared.entity.Id) = .empty,
pending_stats: std.ArrayList(shared.net.UpdateStat) = .empty,
attack_events: std.ArrayList(shared.entity.Id) = .empty,
camera: Camera = .{},
controller: Controller = .{},
teleporter_id: shared.entity.Id = .none,
player_id: shared.entity.Id = .none,
planet_radius: f32 = 0,
menu_screen: MenuScreen = .main,
menu_tuning: MenuTuning = .{},
options: Options = .{},
show_menu_scene: bool = true,
pause_menu_open: bool = false,
options_menu_open: bool = false,
options_menu_return_to_pause: bool = false,
request_quit: bool = false,
stage: u32 = 0,

pub const Entity = struct {
    id: shared.entity.Id = .none,
    kind: shared.entity.Kind,
    teleporter: shared.teleporter.State = .{},
    inventory: shared.Inventory = .{},
    stats: shared.Stats = .{},

    update_motion: ?shared.net.UpdateMotion = null,
    smoothed_moiton_tick: u32 = 0,
    position_error: nz.Vec3(f32) = @splat(0),

    transform: nz.Transform3D(f32) = .{},
};

pub fn init(gpa: std.mem.Allocator) !@This() {
    return .{
        .gpa = gpa,
        .teleporter_bosses = try .initCapacity(gpa, max_entities),
        .pending_spawn = try .initCapacity(gpa, max_entities),
        .pending_despawn = try .initCapacity(gpa, max_entities),
        .pending_stats = try .initCapacity(gpa, max_entities),
        .attack_events = try .initCapacity(gpa, max_entities),
    };
}

pub fn deinit(self: *@This()) void {
    self.entities.deinit(self.gpa);
    self.teleporter_bosses.deinit(self.gpa);
    self.pending_spawn.deinit(self.gpa);
    self.pending_despawn.deinit(self.gpa);
    self.pending_stats.deinit(self.gpa);
    self.attack_events.deinit(self.gpa);
}

pub fn clearSession(self: *@This()) void {
    self.entities.clearRetainingCapacity();
    self.teleporter_bosses.clearRetainingCapacity();
    self.pending_spawn.clearRetainingCapacity();
    self.pending_despawn.clearRetainingCapacity();
    self.pending_stats.clearRetainingCapacity();
    self.attack_events.clearRetainingCapacity();

    self.camera = .{};
    self.controller.clearInput();
    self.controller.releaseMouseButtons();
    self.controller.resetMouseDelta();
    self.teleporter_id = .none;
    self.player_id = .none;
    self.planet_radius = 0;
    self.menu_screen = .main;
    self.show_menu_scene = true;
    self.pause_menu_open = false;
    self.options_menu_open = false;
    self.options_menu_return_to_pause = false;
    self.stage = 0;
}

pub fn spawn(self: *@This(), id: shared.entity.Id) !*Entity {
    try self.entities.put(self.gpa, id, .{ .id = id, .kind = .unknown });
    return self.entities.getPtr(id).?;
}

pub fn getPtr(self: *@This(), id: shared.entity.Id) ?*Entity {
    return self.entities.getPtr(id);
}

pub fn despawn(self: *@This(), id: shared.entity.Id) bool {
    return self.entities.swapRemove(id);
}
