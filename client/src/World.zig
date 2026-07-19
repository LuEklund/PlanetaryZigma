const World = @This();

const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const Camera = @import("system/Camera.zig");
const Controller = @import("system/Controller.zig");
const Particle = @import("system/Particle.zig");
const Model = @import("Renderer/Vulkan/Model.zig");

pub const RenderCommand = union(enum) {
    entity_spawned: struct { id: shared.entity.Id, kind: shared.entity.Kind },
    entity_despawned: shared.entity.Id,
    planet_spawned: u32,
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
render_outbox: std.ArrayList(RenderCommand) = .empty,
particles: std.ArrayList(Particle) = .empty,
camera: Camera = .{},
controller: Controller = .{},
teleporter_id: shared.entity.Id = .none,
player_id: shared.entity.Id = .none,
planet_radius: f32 = 0,
stage: u32 = 0,
prng: std.Random.DefaultPrng,

pub const Entity = struct {
    id: shared.entity.Id = .none,
    kind: shared.entity.Kind,
    player_name: []const u8 = "",
    teleporter: shared.teleporter.State = .{},
    inventory: shared.Inventory = .{},
    stats: shared.Stats = .{},
    currency: u32 = 0,
    interacting: shared.entity.Id = .none,
    update_motion: ?shared.net.UpdateMotion = null,
    smoothed_moiton_tick: u32 = 0,
    position_error: nz.Vec3(f32) = @splat(0),
    animation_state: ?shared.entity.State = null,
    spawn_anim: f32 = 0,
    model: Model.Handle = .default,

    transform: nz.Transform3D(f32) = .{},

    pub fn deinit(self: *Entity, gpa: std.mem.Allocator) void {
        if (self.player_name.len != 0) {
            gpa.free(self.player_name);
            self.player_name = "";
        }
    }
};

pub fn init(gpa: std.mem.Allocator) !World {
    return .{
        .gpa = gpa,
        .teleporter_bosses = try .initCapacity(gpa, shared.max_entities),
        .pending_spawn = try .initCapacity(gpa, shared.max_entities),
        .pending_despawn = try .initCapacity(gpa, shared.max_entities),
        .pending_stats = try .initCapacity(gpa, shared.max_entities),
        .pending_inventory = try .initCapacity(gpa, shared.max_entities),
        .pending_player_names = try .initCapacity(gpa, shared.max_entities),
        .attack_events = try .initCapacity(gpa, shared.max_entities),
        .render_outbox = try .initCapacity(gpa, shared.max_entities * 2 + 8),
        .particles = try .initCapacity(gpa, 4096),
        .prng = .init(0x5EED_BA11),
    };
}

pub fn deinit(self: *World) void {
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
    self.render_outbox.deinit(self.gpa);
    self.particles.deinit(self.gpa);
}

pub fn clearSession(self: *World) void {
    for (self.entities.values()) |*entity| {
        self.render_outbox.appendAssumeCapacity(.{ .entity_despawned = entity.id });
        entity.deinit(self.gpa);
    }
    self.entities.clearRetainingCapacity();
    self.teleporter_bosses.clearRetainingCapacity();
    self.clearPendingSpawns();
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
    self.stage = 0;
}

pub fn clearPendingSpawns(self: *World) void {
    for (self.pending_spawn.items) |entity_info| {
        switch (entity_info.data) {
            .player_name => |player_name| if (player_name.name.len != 0) self.gpa.free(player_name.name),
            .none, .planet_radius, .is_teleporter_boss => {},
        }
    }
    self.pending_spawn.clearRetainingCapacity();
}

pub fn flush(self: *World) !void {
    defer self.clearPendingSpawns();

    for (self.pending_spawn.items) |entity_info| {
        if (self.getPtr(entity_info.id)) |entity| {
            try self.applySpawnData(entity, entity_info);
            continue;
        }
        const entity = try self.spawn(entity_info.id);
        entity.* = .{
            .id = entity_info.id,
            .kind = entity_info.kind,
            .currency = entity_info.currency,
            .transform = .{
                .position = entity_info.position,
                .rotation = .fromVec(entity_info.rotation),
            },
            .update_motion = .{
                .id = entity_info.id,
                .position = entity_info.position,
                .velocity = entity_info.velocity,
                .rotation = entity_info.rotation,
                .tick = entity_info.tick,
            },
        };
        try self.applySpawnData(entity, entity_info);
        switch (entity_info.kind) {
            .player => {
                if (entity_info.id == self.player_id) {
                    self.camera = .{ .transform = .{ .position = .{ 0, 0, 0 } } };
                    self.controller.free_camera = false;
                }
            },
            .planet => {
                const radius: u32 = entity_info.data.planet_radius;
                self.planet_radius = @floatFromInt(radius);
                self.render_outbox.appendAssumeCapacity(.{ .planet_spawned = radius });
                std.log.debug("SPAWNED: Planet {d}", .{radius});
            },
            .projectile_cube => entity.transform.scale = @splat(0.3),
            .projectile_rocket => entity.transform.scale = @splat(0.9),
            .teleporter => self.teleporter_id = entity.id,
            .enemy => {
                if (entity_info.data == .is_teleporter_boss) {
                    entity.transform.scale = @splat(5);
                    self.teleporter_bosses.appendAssumeCapacity(entity.id);
                }
            },
            .unknown, .item, .lootbox => {},
        }
        self.render_outbox.appendAssumeCapacity(.{ .entity_spawned = .{ .id = entity.id, .kind = entity.kind } });
    }

    for (self.pending_player_names.items) |player_name| {
        if (self.getPtr(player_name.id)) |entity| {
            if (entity.kind == .player) try self.setPlayerName(entity, player_name.name);
        }
    }
    self.clearPendingPlayerNames();

    for (self.pending_stats.items) |command| {
        if (self.getPtr(command.id)) |entity| applyStat(entity, command);
    }
    self.pending_stats.clearRetainingCapacity();

    for (self.pending_inventory.items) |command| {
        if (self.getPtr(command.id)) |entity| entity.inventory.set(command.item_kind, command.set);
    }
    self.pending_inventory.clearRetainingCapacity();

    for (self.pending_despawn.items) |id| {
        if (self.getPtr(id) == null) continue;
        if (std.mem.indexOfScalar(shared.entity.Id, self.teleporter_bosses.items, id)) |index_of_boss| {
            _ = self.teleporter_bosses.swapRemove(index_of_boss);
        }
        if (id == self.player_id) self.controller.free_camera = true;
        self.render_outbox.appendAssumeCapacity(.{ .entity_despawned = id });
        _ = self.despawn(id);
    }
    self.pending_despawn.clearRetainingCapacity();
}

pub fn applySpawnData(self: *World, entity: *Entity, entity_info: shared.net.SpawnEntity) !void {
    switch (entity_info.data) {
        .player_name => |player_name| {
            if (entity.kind == .player) try self.setPlayerName(entity, player_name.name);
        },
        .none, .planet_radius, .is_teleporter_boss => {},
    }
}

pub fn applyStat(entity: *Entity, command: shared.net.UpdateStat) void {
    switch (command.amount) {
        .set_current => |value| entity.stats.setCurrent(command.stat_kind, value),
        .set_max => |value| entity.stats.setMax(command.stat_kind, value),
    }
}

pub fn spawn(self: *World, id: shared.entity.Id) !*Entity {
    try self.entities.put(self.gpa, id, .{ .id = id, .kind = .unknown });
    return self.entities.getPtr(id).?;
}

pub fn getPtr(self: *World, id: shared.entity.Id) ?*Entity {
    return self.entities.getPtr(id);
}

pub fn setPlayerName(self: *World, entity: *Entity, name: []const u8) !void {
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

pub fn despawn(self: *World, id: shared.entity.Id) bool {
    if (self.entities.getPtr(id)) |entity| entity.deinit(self.gpa);
    return self.entities.swapRemove(id);
}

pub fn clearPendingPlayerNames(self: *World) void {
    for (self.pending_player_names.items) |player_name| {
        if (player_name.name.len != 0) self.gpa.free(player_name.name);
    }
    self.pending_player_names.clearRetainingCapacity();
}
