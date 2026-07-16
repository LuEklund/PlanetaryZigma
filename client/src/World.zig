const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const Camera = @import("system/Camera.zig");
const Controller = @import("system/Controller.zig");

pub const MenuScreen = enum {
    main,
    multiplayer,
};

pub const OptionsTab = enum {
    gameplay,
    keyboard_mouse,
    video,
    graphics,
};

pub const Options = struct {
    tab: OptionsTab = .gameplay,
    show_hud_stats: bool = true,
    show_crosshair: bool = true,
    mouse_sensitivity: f32 = 1.0,
    invert_y: bool = false,
    fullscreen: bool = false,
    fov_rad: f32 = 1.5,

    pub fn cycleMouseSensitivity(self: *Options) void {
        const values = [_]f32{ 0.5, 0.75, 1.0, 1.25, 1.5, 2.0 };
        self.mouse_sensitivity = cycleF32(values, self.mouse_sensitivity);
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
pending_inventory: std.ArrayList(shared.net.UpdateInventory) = .empty,
pending_player_names: std.ArrayList(shared.net.PlayerNameUpdate) = .empty,
attack_events: std.ArrayList(shared.entity.Id) = .empty,
particles: std.ArrayList(Particle) = .empty,
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
prng: std.Random.DefaultPrng,

pub const Entity = struct {
    id: shared.entity.Id = .none,
    kind: shared.entity.Kind,
    player_name: []const u8 = "",
    teleporter: shared.teleporter.State = .{},
    inventory: shared.Inventory = .{},
    stats: shared.Stats = .{},

    update_motion: ?shared.net.UpdateMotion = null,
    smoothed_moiton_tick: u32 = 0,
    position_error: nz.Vec3(f32) = @splat(0),

    transform: nz.Transform3D(f32) = .{},

    pub fn deinit(self: *Entity, gpa: std.mem.Allocator) void {
        if (self.player_name.len != 0) {
            gpa.free(self.player_name);
            self.player_name = "";
        }
    }
};

pub const Particle = struct {
    position: nz.Vec3(f32),
    velocity: nz.Vec3(f32),
    lifetime: f32,
    max_lifetime: f32,
    scale: f32,
};

pub fn init(gpa: std.mem.Allocator) !@This() {
    return .{
        .gpa = gpa,
        .teleporter_bosses = try .initCapacity(gpa, shared.max_entities),
        .pending_spawn = try .initCapacity(gpa, shared.max_entities),
        .pending_despawn = try .initCapacity(gpa, shared.max_entities),
        .pending_stats = try .initCapacity(gpa, shared.max_entities),
        .pending_inventory = try .initCapacity(gpa, shared.max_entities),
        .pending_player_names = try .initCapacity(gpa, shared.max_entities),
        .attack_events = try .initCapacity(gpa, shared.max_entities),
        .particles = try .initCapacity(gpa, 512),
        .prng = .init(0x5EED_BA11),
    };
}

pub fn deinit(self: *@This()) void {
    for (self.entities.values()) |*entity| {
        entity.deinit(self.gpa);
    }
    self.entities.deinit(self.gpa);
    self.teleporter_bosses.deinit(self.gpa);
    self.pending_spawn.deinit(self.gpa);
    self.pending_despawn.deinit(self.gpa);
    self.pending_stats.deinit(self.gpa);
    self.pending_inventory.deinit(self.gpa);
    clearPendingPlayerNames(self);
    self.pending_player_names.deinit(self.gpa);
    self.attack_events.deinit(self.gpa);
    self.particles.deinit(self.gpa);
}

pub fn clearSession(self: *@This()) void {
    self.entities.clearRetainingCapacity();
    self.teleporter_bosses.clearRetainingCapacity();
    self.pending_spawn.clearRetainingCapacity();
    self.pending_despawn.clearRetainingCapacity();
    self.pending_stats.clearRetainingCapacity();
    self.pending_inventory.clearRetainingCapacity();
    clearPendingPlayerNames(self);
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

pub fn setPlayerName(self: *@This(), entity: *Entity, name: []const u8) !void {
    var name_buffer: [shared.max_player_name_len]u8 = undefined;
    const sanitized = sanitizePlayerName(&name_buffer, name);
    if (std.mem.eql(u8, entity.player_name, sanitized)) return;
    if (entity.player_name.len != 0) {
        self.gpa.free(entity.player_name);
        entity.player_name = "";
    }
    entity.player_name = if (sanitized.len == 0) "" else try self.gpa.dupe(u8, sanitized);
}

fn sanitizePlayerName(buffer: *[shared.max_player_name_len]u8, raw: []const u8) []const u8 {
    var len: usize = 0;
    for (std.mem.trim(u8, raw, " \t\r\n")) |char| {
        if (len >= buffer.len) break;
        if (char < 32 or char > 126) continue;
        buffer[len] = char;
        len += 1;
    }
    return buffer[0..len];
}

pub fn despawn(self: *@This(), id: shared.entity.Id) bool {
    if (self.entities.getPtr(id)) |entity| entity.deinit(self.gpa);
    return self.entities.swapRemove(id);
}

fn appendParticle(self: *@This(), particle: Particle) void {
    if (self.particles.items.len >= self.particles.capacity and self.particles.items.len > 0) {
        _ = self.particles.swapRemove(0);
    }
    self.particles.appendAssumeCapacity(particle);
}

pub fn clearPendingPlayerNames(self: *@This()) void {
    for (self.pending_player_names.items) |player_name| {
        if (player_name.name.len != 0) self.gpa.free(player_name.name);
    }
    self.pending_player_names.clearRetainingCapacity();
}

fn particleSurfaceUp(position: nz.Vec3(f32)) nz.Vec3(f32) {
    const distance = nz.vec.length(position);
    return if (distance > 0.001) nz.vec.scale(position, 1.0 / distance) else .{ 0, 1, 0 };
}

fn surfaceBiasedDirection(random: std.Random, surface_up: nz.Vec3(f32)) nz.Vec3(f32) {
    var direction = nz.vec.randomUnitVector(nz.Vec3(f32), random);
    const outward = nz.vec.dot(direction, surface_up);
    if (outward < 0.2) {
        direction = nz.vec.normalize(direction + nz.vec.scale(surface_up, 0.35 - outward));
    }
    return direction;
}

pub fn spawnRocketExplosion(self: *@This(), position: nz.Vec3(f32)) void {
    const random = self.prng.random();
    const surface_up = particleSurfaceUp(position);
    const spawn_position = position + nz.vec.scale(surface_up, 1.15);
    const center_particles = [_]struct {
        offset: nz.Vec3(f32),
        velocity: nz.Vec3(f32),
        scale: f32,
        lifetime: f32,
    }{
        .{ .offset = .{ 0, 0, 0 }, .velocity = .{ 0, 0, 0 }, .scale = 2.2, .lifetime = 0.34 },
        .{ .offset = .{ -0.15, 0.2, 0.2 }, .velocity = .{ -0.5, 0.7, 0.6 }, .scale = 1.95, .lifetime = 0.38 },
        .{ .offset = .{ 0.2, -0.15, -0.25 }, .velocity = .{ 0.7, -0.4, -0.8 }, .scale = 1.75, .lifetime = 0.4 },
        .{ .offset = .{ 0.45, 0.1, 0 }, .velocity = .{ 1.8, 0.4, 0 }, .scale = 1.55, .lifetime = 0.42 },
        .{ .offset = .{ -0.35, -0.2, 0.1 }, .velocity = .{ -1.2, -0.7, 0.4 }, .scale = 1.35, .lifetime = 0.46 },
        .{ .offset = .{ 0.05, 0.35, -0.15 }, .velocity = .{ 0.2, 1.1, -0.5 }, .scale = 1.2, .lifetime = 0.5 },
        .{ .offset = .{ 0.3, -0.4, 0.2 }, .velocity = .{ 0.9, -1.1, 0.5 }, .scale = 1.1, .lifetime = 0.44 },
        .{ .offset = .{ -0.45, 0.25, -0.1 }, .velocity = .{ -1.0, 0.8, -0.3 }, .scale = 1.0, .lifetime = 0.48 },
    };

    for (center_particles) |particle| {
        const tangent_offset = particle.offset - nz.vec.scale(surface_up, nz.vec.dot(particle.offset, surface_up));
        self.appendParticle(.{
            .position = spawn_position + tangent_offset,
            .velocity = particle.velocity + nz.vec.scale(surface_up, 1.4),
            .lifetime = particle.lifetime,
            .max_lifetime = particle.lifetime,
            .scale = particle.scale,
        });
    }

    for (0..2) |burst_index| {
        const burst_f: f32 = @floatFromInt(burst_index);
        for (0..16) |spark_index| {
            const direction = surfaceBiasedDirection(random, surface_up);
            const spark_f: f32 = @floatFromInt(spark_index);
            const lifetime = 0.42 + random.float(f32) * 0.28 + burst_f * 0.06;
            const speed = 12.0 + random.float(f32) * 7.0 + burst_f * 4.0;
            const scale = (0.3 + random.float(f32) * 0.22) * (1.0 - burst_f * 0.15);
            self.appendParticle(.{
                .position = spawn_position + nz.vec.scale(direction, burst_f * 0.35 + spark_f * 0.01),
                .velocity = nz.vec.scale(direction, speed),
                .lifetime = lifetime,
                .max_lifetime = lifetime,
                .scale = scale,
            });
        }
    }
}

pub fn updateParticles(self: *@This(), delta_time: f32) void {
    var index: usize = 0;
    while (index < self.particles.items.len) {
        const particle = &self.particles.items[index];
        particle.lifetime -= delta_time;
        if (particle.lifetime <= 0) {
            _ = self.particles.swapRemove(index);
            continue;
        }

        particle.position += nz.vec.scale(particle.velocity, delta_time);
        particle.velocity = nz.vec.scale(particle.velocity, std.math.pow(f32, 0.08, delta_time));
        index += 1;
    }
}
