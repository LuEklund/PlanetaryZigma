const World = @This();

const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const Camera = @import("system/Camera.zig");
const Chat = @import("system/Chat.zig");
const Controller = @import("system/Controller.zig");
const Options = @import("Options.zig");
const Emitter = @import("shared").Emitter;
const DrawList = @import("render").DrawList;

pub const DamageEvent = struct {
    target: shared.entity.Id,
    source: shared.entity.Id,
    position: nz.Vec3(f32),
    delta: f32,
};

gpa: std.mem.Allocator,
entities: std.AutoArrayHashMapUnmanaged(shared.entity.Id, Entity) = .empty,
teleporter_bosses: std.ArrayList(shared.entity.Id) = .empty,
pending_spawn: std.ArrayList(shared.net.SpawnEntity) = .empty,
pending_despawn: std.ArrayList(shared.entity.Id) = .empty,
pending_healths: std.ArrayList(shared.net.UpdateHealth) = .empty,
pending_inventory: std.ArrayList(shared.net.UpdateInventory) = .empty,
trigger_events: std.ArrayList(shared.net.Event.Trigger) = .empty,
deaths: std.ArrayList(shared.entity.Id) = .empty,
effects: std.ArrayList(Emitter.Spawn) = .empty,
damage_events: std.ArrayList(DamageEvent) = .empty,
options: Options = .{},
camera: Camera = .{},
controller: Controller = .{},
chat: Chat = .{},
teleporter_id: shared.entity.Id = .none,
player_id: shared.entity.Id = .none,
planet: shared.Planet = .empty,
elapsed_time: f32 = 0,
delta_time: f32 = 0,
fps: f32 = 0,
go_again_pending: bool = false,
stage: u32 = 0,
prng: std.Random.DefaultPrng,

pub const Entity = struct {
    id: shared.entity.Id = .none,
    kind: shared.entity.Kind,
    player_name: shared.net.PlayerName = .copy(""),
    teleporter: shared.teleporter.State = .{},
    inventory: shared.Inventory = .{},
    health: f32 = 0,
    max_health: f32 = 0,
    currency: u32 = 0,
    interacting: shared.entity.Id = .none,
    motion: Motion = .{},
    override_animation_state: ?shared.entity.State = null,
    stun_time: f32 = 0,
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
};

pub fn init(gpa: std.mem.Allocator) !World {
    return .{
        .gpa = gpa,
        .teleporter_bosses = try .initCapacity(gpa, shared.max_entities),
        .pending_spawn = try .initCapacity(gpa, shared.max_entities),
        .pending_despawn = try .initCapacity(gpa, shared.max_entities),
        .pending_healths = try .initCapacity(gpa, shared.max_entities),
        .pending_inventory = try .initCapacity(gpa, shared.max_entities),
        .trigger_events = try .initCapacity(gpa, shared.max_entities),
        .deaths = try .initCapacity(gpa, shared.max_entities),
        .effects = try .initCapacity(gpa, shared.max_entities),
        .damage_events = try .initCapacity(gpa, 128),
        .prng = .init(0x5EED_BA11),
    };
}

pub fn deinit(self: *World) void {
    self.entities.deinit(self.gpa);
    self.teleporter_bosses.deinit(self.gpa);
    self.pending_spawn.deinit(self.gpa);
    self.pending_despawn.deinit(self.gpa);
    self.pending_healths.deinit(self.gpa);
    self.pending_inventory.deinit(self.gpa);
    self.trigger_events.deinit(self.gpa);
    self.deaths.deinit(self.gpa);
    self.effects.deinit(self.gpa);
    self.damage_events.deinit(self.gpa);
    self.planet.deinit(self.gpa);
}

pub fn clear(self: *World) void {
    self.go_again_pending = false;
    self.entities.clearRetainingCapacity();
    self.teleporter_bosses.clearRetainingCapacity();
    self.pending_spawn.clearRetainingCapacity();

    self.pending_despawn.clearRetainingCapacity();
    self.pending_healths.clearRetainingCapacity();
    self.pending_inventory.clearRetainingCapacity();
    self.trigger_events.clearRetainingCapacity();
    self.deaths.clearRetainingCapacity();
    self.effects.clearRetainingCapacity();
    self.damage_events.clearRetainingCapacity();

    self.camera = .{};
    self.chat = .{};
    self.controller.clearInput();
    self.controller.releaseMouseButtons();
    self.controller.resetMouseDelta();
    self.teleporter_id = .none;
    self.player_id = .none;
    self.stage = 0;
}

pub fn flush(self: *World) !void {
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
                    setPlayerName(entity, entity_info.data.player_name.slice());
                }
                if (entity_info.id == self.player_id) {
                    self.camera = .{ .transform = .{ .position = .{ 0, 0, 0 } } };
                    self.controller.free_camera = false;
                }
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
    }

    for (self.pending_healths.items) |command| {
        if (self.getPtr(command.id)) |entity| self.applyHealth(entity, command);
    }
    self.pending_healths.clearRetainingCapacity();

    for (self.pending_inventory.items) |command| {
        if (self.getPtr(command.id)) |entity| applyInventory(entity, command);
    }
    self.pending_inventory.clearRetainingCapacity();

    defer self.pending_despawn.clearRetainingCapacity();
    for (self.pending_despawn.items) |id| {
        const entity = self.getPtr(id) orelse continue;
        if (std.mem.indexOfScalar(shared.entity.Id, self.teleporter_bosses.items, id)) |index_of_boss| {
            _ = self.teleporter_bosses.swapRemove(index_of_boss);
        }
        if (id == self.player_id) self.controller.free_camera = true;
        if (entity.flags.is_dying or shared.entity.spec(entity.kind).death_duration > 0) {
            self.deaths.appendAssumeCapacity(id);
        }
        _ = self.despawn(id);
    }
}

pub fn queueSpawn(self: *World, spawn_entity: shared.net.SpawnEntity) void {
    self.pending_spawn.appendAssumeCapacity(spawn_entity);
}

pub fn applyInventory(entity: *Entity, command: shared.net.UpdateInventory) void {
    entity.inventory.set(command.item_kind, command.set);
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
    if (!entity.kind.hasHealth()) return;
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

pub fn spawn(self: *World, id: shared.entity.Id) !*Entity {
    try self.entities.put(self.gpa, id, .{ .id = id, .kind = .unknown });
    return self.entities.getPtr(id).?;
}

pub fn getPtr(self: *World, id: shared.entity.Id) ?*Entity {
    return self.entities.getPtr(id);
}

pub fn setPlayerName(entity: *Entity, name: []const u8) void {
    var name_buffer: [shared.max_player_name_len]u8 = undefined;
    entity.player_name = .copy(sanitizePlayerName(&name_buffer, name));
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
    return self.entities.swapRemove(id);
}
