const World = @This();

const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const Camera = @import("system/Camera.zig");
const Chat = @import("system/Chat.zig");
const Controller = @import("system/Controller.zig");
const Options = @import("Options.zig");
const Animator = @import("graphics").Animator;
const DrawList = @import("renderer_contract").DrawList;

pub const DamageEvent = struct {
    target: shared.entity.Id,
    source: shared.entity.Id,
    position: nz.Vec3(f32),
    delta: f32,
};

gpa: std.mem.Allocator,
entities: std.AutoArrayHashMapUnmanaged(shared.entity.Id, Entity) = .empty,
teleporter_bosses: std.ArrayList(shared.entity.Id) = .empty,
dying: std.ArrayList(Dying) = .empty,
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

pub const Dying = struct {
    kind: shared.entity.Kind,
    transform: nz.Transform3D(f32),
    animation: Animator.Handle,
    elapsed: f32,
};

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
    override_animation_loop: ?shared.entity.Loop = null,
    stun_time: f32 = 0,
    item: ?shared.Item.Kind = null,
    flags: Flags = .{},
    animation: Animator.Handle = .none,
    spawned_at: f32 = 0,

    transform: nz.Transform3D(f32) = .{},

    pub const Motion = struct {
        update: ?shared.net.UpdateMotion = null,
        smoothed_tick: u32 = 0,
        position_error: nz.Vec3(f32) = @splat(0),
    };

    pub const Flags = packed struct {
        is_teleporter_boss: bool = false,
    };

    pub fn stat(self: *const Entity, stat_kind: shared.Item.Stat) f32 {
        return shared.Item.Stat.value(stat_kind, &self.kind.spec().base_stats, self.inventory);
    }
};

pub fn init(gpa: std.mem.Allocator) !World {
    return .{
        .gpa = gpa,
        .teleporter_bosses = try .initCapacity(gpa, shared.max_entities),
        .dying = try .initCapacity(gpa, shared.max_entities),
        .damage_events = try .initCapacity(gpa, 128),
        .prng = .init(0x5EED_BA11),
    };
}

pub fn deinit(self: *World) void {
    self.entities.deinit(self.gpa);
    self.teleporter_bosses.deinit(self.gpa);
    self.dying.deinit(self.gpa);
    self.damage_events.deinit(self.gpa);
    self.planet.deinit(self.gpa);
}

pub fn clear(self: *World) void {
    self.go_again_pending = false;
    self.entities.clearRetainingCapacity();
    self.teleporter_bosses.clearRetainingCapacity();
    self.dying.clearRetainingCapacity();
    self.damage_events.clearRetainingCapacity();

    self.camera = .{};
    self.chat = .{};
    self.teleporter_id = .none;
    self.player_id = .none;
    self.stage = 0;
}

pub fn update(self: *World, packets: []const shared.net.ServerPacket) !void {
    for (packets) |packet| switch (packet) {
        .acknowledge => |acknowledge| {
            self.player_id = acknowledge.id;
        },
        .spawn_entity => |spawn_entity| {
            if (spawn_entity.kind == .unknown) {
                std.log.err("spawn with unknown entity kind, ignoring", .{});
                continue;
            }
            try self.applySpawn(spawn_entity);
        },
        .spawn_planet => |radius| {
            try self.planet.sync(self.gpa, radius);
        },
        .despawn_entity => |despawn_entity| {
            const entity = self.getPtr(despawn_entity.id) orelse continue;
            if (std.mem.indexOfScalar(shared.entity.Id, self.teleporter_bosses.items, despawn_entity.id)) |index_of_boss| {
                _ = self.teleporter_bosses.swapRemove(index_of_boss);
            }
            if (despawn_entity.id == self.player_id) self.controller.free_camera = true;
            self.dying.appendAssumeCapacity(.{
                .kind = entity.kind,
                .transform = entity.transform,
                .animation = entity.animation,
                .elapsed = 0,
            });
            _ = self.despawn(despawn_entity.id);
        },
        .motion => |motion| {
            const entity = self.getPtr(motion.id) orelse continue;
            entity.motion.update = motion;
        },
        .health => |health| {
            const entity = self.getPtr(health.id) orelse continue;
            self.applyHealth(entity, health);
        },
        .inventory => |inventory| {
            const entity = self.getPtr(inventory.id) orelse continue;
            applyInventory(entity, inventory);
        },
        .set_currency => |set_currency| {
            const entity = self.getPtr(set_currency.id) orelse continue;
            entity.currency = set_currency.amount;
        },
        .chat_message => |chat_message| {
            const sender = self.getPtr(chat_message.id);
            const name = if (sender != null and sender.?.player_name.slice().len != 0)
                sender.?.player_name.slice()
            else
                shared.default_player_name;
            self.chat.push(name, chat_message.text, self.elapsed_time);
        },
        .server_tick, .event => {},
    };
}

pub fn applySpawn(self: *World, entity_info: shared.net.SpawnEntity) !void {
    if (self.getPtr(entity_info.id) != null) return;
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
        .item_pickup => {
            if (entity_info.data == .item) entity.item = entity_info.data.item;
        },
        .unknown, .lootbox, .platform, .target_dummy => {},
    }
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
    const was_downed = entity.health <= 0;
    switch (command.amount) {
        .set_current => |value| entity.health = value,
        .set_max => |value| entity.max_health = value,
    }
    if (entity.max_health <= 0) return;
    if (entity.id != self.player_id) return;
    const downed = entity.health <= 0;
    if (downed != was_downed) {
        self.controller.free_camera = downed;
        if (!downed) {
            self.camera = .{ .transform = .{ .position = .{ 0, 0, 0 } } };
        }
    }
}

pub fn spawn(self: *World, id: shared.entity.Id) !*Entity {
    try self.entities.put(self.gpa, id, .{ .id = id, .kind = .unknown, .spawned_at = self.elapsed_time });
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
