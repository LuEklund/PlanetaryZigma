const World = @This();

const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const Camera = @import("system/Camera.zig");
const Chat = @import("system/Chat.zig");
const Controller = @import("system/Controller.zig");
const Emitter = @import("system/Emitter.zig");
const Model = @import("asset/Model.zig");
const AnimationInstance = @import("asset/AnimationInstance.zig");

pub const DamageEvent = struct {
    target: shared.entity.Id,
    source: shared.entity.Id,
    position: nz.Vec3(f32),
    delta: f32,
};

pub const RenderCommand = union(enum) {
    entity_spawned: struct { id: shared.entity.Id, kind: shared.entity.Kind },
    entity_despawned: shared.entity.Id,
};

mutex: std.Io.Mutex = .init,
gpa: std.mem.Allocator,
entities: std.AutoArrayHashMapUnmanaged(shared.entity.Id, Entity) = .empty,
teleporter_bosses: std.ArrayList(shared.entity.Id) = .empty,
pending_spawn: std.ArrayList(shared.net.SpawnEntity) = .empty,
pending_despawn: std.ArrayList(shared.entity.Id) = .empty,
pending_stats: std.ArrayList(shared.net.UpdateStat) = .empty,
pending_inventory: std.ArrayList(shared.net.UpdateInventory) = .empty,
attack_events: std.ArrayList(shared.entity.Id) = .empty,
render_outbox: std.ArrayList(RenderCommand) = .empty,
emitters: std.ArrayList(Emitter) = .empty,
damage_events: std.ArrayList(DamageEvent) = .empty,
camera: Camera = .{},
controller: Controller = .{},
chat: Chat = .{},
teleporter_id: shared.entity.Id = .none,
player_id: shared.entity.Id = .none,
planet_radius: f32 = 0,
stage: u32 = 0,
chunk_view_distance: i32 = 1,
prng: std.Random.DefaultPrng,

pub const Entity = struct {
    id: shared.entity.Id = .none,
    kind: shared.entity.Kind,
    player_name: []const u8 = "",
    teleporter: shared.teleporter.State = .{},
    inventory: shared.Inventory = .{},
    stats: shared.Stats = .init(.initFill(0)),
    currency: u32 = 0,
    interacting: shared.entity.Id = .none,
    motion: Motion = .{},
    override_animation_state: ?shared.entity.State = null,
    model_handle: Model.Handle = .{ .generated = .default },
    flags: Flags = .{},

    transform: nz.Transform3D(f32) = .{},

    pub const Motion = struct {
        update: ?shared.net.UpdateMotion = null,
        smoothed_tick: u32 = 0,
        position_error: nz.Vec3(f32) = @splat(0),
    };

    pub const Flags = packed struct {
        is_dying: bool = false,
    };

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
        .attack_events = try .initCapacity(gpa, shared.max_entities),
        .render_outbox = try .initCapacity(gpa, shared.max_entities * 2 + 8),
        .emitters = try .initCapacity(gpa, 256),
        .damage_events = try .initCapacity(gpa, 128),
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
    self.attack_events.deinit(self.gpa);
    self.render_outbox.deinit(self.gpa);
    self.emitters.deinit(self.gpa);
    self.damage_events.deinit(self.gpa);
}

pub fn clearSession(self: *World) void {
    for (self.entities.values()) |*entity| {
        self.render_outbox.appendAssumeCapacity(.{ .entity_despawned = entity.id });
        entity.deinit(self.gpa);
    }
    self.entities.clearRetainingCapacity();
    self.teleporter_bosses.clearRetainingCapacity();
    self.pending_spawn.clearRetainingCapacity();

    self.pending_despawn.clearRetainingCapacity();
    self.pending_stats.clearRetainingCapacity();
    self.pending_inventory.clearRetainingCapacity();
    self.attack_events.clearRetainingCapacity();
    self.damage_events.clearRetainingCapacity();

    self.camera = .{};
    self.chat = .{};
    self.controller.clearInput();
    self.controller.releaseMouseButtons();
    self.controller.resetMouseDelta();
    self.teleporter_id = .none;
    self.player_id = .none;
    self.planet_radius = 0;
    self.stage = 0;
}

pub fn flush(self: *World, delta_time: f32, instances: *std.AutoHashMap(shared.entity.Id, AnimationInstance)) !void {
    defer self.pending_spawn.clearRetainingCapacity();
    for (self.pending_spawn.items) |entity_info| {
        // Spawn data is per-kind creation payload: read ONCE, here, in the switch below.
        // A re-sent spawn for an entity we already have carries nothing new.
        if (self.getPtr(entity_info.id) != null) continue;
        const entity = try self.spawn(entity_info.id);
        entity.* = .{
            .id = entity_info.id,
            .kind = entity_info.kind,
            .currency = entity_info.currency,
            .transform = .{
                .position = entity_info.position,
                .rotation = .fromVec(entity_info.rotation),
            },
            .motion = .{ .update = .{
                .id = entity_info.id,
                .position = entity_info.position,
                .velocity = entity_info.velocity,
                .rotation = entity_info.rotation,
                .tick = entity_info.tick,
            } },
        };
        switch (entity_info.kind) {
            .player => {
                if (entity_info.data == .player_name) {
                    try self.setPlayerName(entity, entity_info.data.player_name.slice());
                }
                if (entity_info.id == self.player_id) {
                    self.camera = .{ .transform = .{ .position = .{ 0, 0, 0 } } };
                    self.controller.free_camera = false;
                }
            },
            .planet => {
                const radius: u32 = entity_info.data.planet_radius;
                self.planet_radius = @floatFromInt(radius);
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
            .unknown, .item, .lootbox, .platform => {},
        }
        self.render_outbox.appendAssumeCapacity(.{ .entity_spawned = .{ .id = entity.id, .kind = entity.kind } });
    }

    for (self.pending_stats.items) |command| {
        if (self.getPtr(command.id)) |entity| self.applyStat(entity, command);
    }
    self.pending_stats.clearRetainingCapacity();

    for (self.pending_inventory.items) |command| {
        if (self.getPtr(command.id)) |entity| entity.inventory.set(command.item_kind, command.set);
    }
    self.pending_inventory.clearRetainingCapacity();

    var despawn_index: usize = 0;
    while (despawn_index < self.pending_despawn.items.len) {
        const id = self.pending_despawn.items[despawn_index];
        if (self.getPtr(id)) |entity| {
            entity.motion.update = null;
            entity.flags.is_dying = true;
            if (instances.getPtr(id)) |instance| {
                if (instance.deathDuration() > 0) {
                    instance.death_time += delta_time;
                    if (!instance.deathDone()) {
                        despawn_index += 1;
                        continue;
                    }
                }
            }
        }
        _ = self.pending_despawn.swapRemove(despawn_index);
        if (self.getPtr(id) == null) continue;
        if (std.mem.indexOfScalar(shared.entity.Id, self.teleporter_bosses.items, id)) |index_of_boss| {
            _ = self.teleporter_bosses.swapRemove(index_of_boss);
        }
        if (id == self.player_id) self.controller.free_camera = true;
        self.render_outbox.appendAssumeCapacity(.{ .entity_despawned = id });
        _ = self.despawn(id);
    }
}

pub fn applyStat(self: *World, entity: *Entity, command: shared.net.UpdateStat) void {
    if (command.stat_kind == .health and command.source != .none and command.amount == .set_current) {
        const delta = entity.stats.current.get(.health) - command.amount.set_current;
        if (delta != 0 and self.damage_events.items.len < self.damage_events.capacity) {
            self.damage_events.appendAssumeCapacity(.{
                .target = entity.id,
                .source = command.source,
                .position = entity.transform.position,
                .delta = delta,
            });
        }
    }
    switch (command.amount) {
        .set_current => |value| entity.stats.current.set(command.stat_kind, value),
        .set_max => |value| entity.stats.max.set(command.stat_kind, value),
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
