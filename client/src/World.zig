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
io: std.Io,
entities: std.AutoArrayHashMapUnmanaged(shared.entity.Id, Entity) = .empty,
teleporter_bosses: std.ArrayList(shared.entity.Id) = .empty,
pending_spawn: std.ArrayList(shared.net.SpawnEntity) = .empty,
pending_despawn: std.ArrayList(shared.entity.Id) = .empty,
pending_healths: std.ArrayList(shared.net.UpdateHealth) = .empty,
pending_inventory: std.ArrayList(shared.net.UpdateInventory) = .empty,
trigger_events: std.ArrayList(shared.net.Event.Trigger) = .empty,
render_outbox: std.ArrayList(RenderCommand) = .empty,
emitters: Emitter.List,
damage_events: std.ArrayList(DamageEvent) = .empty,
camera: Camera = .{},
controller: Controller = .{},
chat: Chat = .{},
teleporter_id: shared.entity.Id = .none,
player_id: shared.entity.Id = .none,
planet_radius: f32 = 0,
elapsed_time: f32 = 0,
delta_time: f32 = 0,
fps: f32 = 0,
go_again_pending: bool = false,
stage: u32 = 0,
chunk_view_distance: i32 = 1,
prng: std.Random.DefaultPrng,

pub const Entity = struct {
    id: shared.entity.Id = .none,
    kind: shared.entity.Kind,
    player_name: []const u8 = "",
    teleporter: shared.teleporter.State = .{},
    inventory: shared.Inventory = .{},
    health: f32 = 0,
    max_health: f32 = 0,
    currency: u32 = 0,
    interacting: shared.entity.Id = .none,
    motion: Motion = .{},
    override_animation_state: ?shared.entity.State = null,
    stun_time: f32 = 0,
    model_handle: ?Model.Handle = null,
    flags: Flags = .{},

    transform: nz.Transform3D(f32) = .{},

    pub const Motion = struct {
        update: ?shared.net.UpdateMotion = null,
        smoothed_tick: u32 = 0,
        position_error: nz.Vec3(f32) = @splat(0),
    };

    pub const Flags = packed struct {
        is_dying: bool = false,
        is_teleporter_boss: bool = false,
    };

    pub fn stat(self: *const Entity, stat_kind: shared.Item.Stat) f32 {
        return shared.Item.Stat.value(stat_kind, self.kind, self.inventory);
    }

    pub fn deinit(self: *Entity, gpa: std.mem.Allocator) void {
        if (self.player_name.len != 0) {
            gpa.free(self.player_name);
            self.player_name = "";
        }
    }
};

pub fn init(gpa: std.mem.Allocator, io: std.Io) !World {
    return .{
        .gpa = gpa,
        .io = io,
        .teleporter_bosses = try .initCapacity(gpa, shared.max_entities),
        .pending_spawn = try .initCapacity(gpa, shared.max_entities),
        .pending_despawn = try .initCapacity(gpa, shared.max_entities),
        .pending_healths = try .initCapacity(gpa, shared.max_entities),
        .pending_inventory = try .initCapacity(gpa, shared.max_entities),
        .trigger_events = try .initCapacity(gpa, shared.max_entities),
        .render_outbox = try .initCapacity(gpa, shared.max_entities * 2 + 8),
        .damage_events = try .initCapacity(gpa, 128),
        .prng = .init(0x5EED_BA11),
        .emitters = @splat(Emitter.free),
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
    self.pending_healths.deinit(self.gpa);
    self.pending_inventory.deinit(self.gpa);
    self.trigger_events.deinit(self.gpa);
    self.render_outbox.deinit(self.gpa);
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
    self.pending_healths.clearRetainingCapacity();
    self.pending_inventory.clearRetainingCapacity();
    self.trigger_events.clearRetainingCapacity();
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

pub fn flush(self: *World, instances: *std.AutoHashMap(shared.entity.Id, AnimationInstance)) !void {
    defer self.pending_spawn.clearRetainingCapacity();
    for (self.pending_spawn.items) |entity_info| {
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
                std.log.info("SPAWNED: Planet {d}", .{radius});
            },
            .projectile_cube => entity.transform.scale = @splat(0.3),
            .projectile_rocket => entity.transform.scale = @splat(0.9),
            .teleporter => self.teleporter_id = entity.id,
            .enemy => {
                if (entity_info.data == .is_teleporter_boss) {
                    entity.flags.is_teleporter_boss = true;
                    self.teleporter_bosses.appendAssumeCapacity(entity.id);
                }
            },
            .unknown, .item, .lootbox, .platform, .target_dummy => {},
        }
        self.render_outbox.appendAssumeCapacity(.{ .entity_spawned = .{ .id = entity.id, .kind = entity.kind } });
    }

    for (self.pending_healths.items) |command| {
        if (self.getPtr(command.id)) |entity| self.applyHealth(entity, command);
    }
    self.pending_healths.clearRetainingCapacity();

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
                if (instance.deathDuration() > 0 and !instance.deathDone()) {
                    despawn_index += 1;
                    continue;
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

pub fn applyHealth(self: *World, entity: *Entity, command: shared.net.UpdateHealth) void {
    if (command.source != .none and command.amount == .set_current) {
        const delta = entity.health - command.amount.set_current;
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
        .set_current => |value| entity.health = value,
        .set_max => |value| entity.max_health = value,
    }
    if (entity.kind == .player) {
        if (entity.health <= 0 and !entity.flags.is_dying) {
            entity.flags.is_dying = true;
            entity.motion.update = null;
            if (entity.id == self.player_id) self.controller.free_camera = true;
        } else if (entity.health > 0 and entity.flags.is_dying) {
            entity.flags.is_dying = false;
            if (entity.id == self.player_id) {
                self.controller.free_camera = false;
                self.camera = .{ .transform = .{ .position = .{ 0, 0, 0 } } };
            }
        }
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
