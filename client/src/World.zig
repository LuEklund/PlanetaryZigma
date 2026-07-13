const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const Camera = @import("system/Camera.zig");
const Controller = @import("system/Controller.zig");

pub const max_entities: usize = 1024;

pub const MenuScreen = enum {
    main,
    multiplayer,
    settings,
};

pub const MenuEditMode = enum {
    camera,
    planet,
    bozo,
};

pub const MenuTuning = struct {
    edit_mode: MenuEditMode = .camera,
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
show_menu_scene: bool = true,
request_quit: bool = false,

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
