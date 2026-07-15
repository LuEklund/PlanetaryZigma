const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const Camera = @import("system/Camera.zig");
const Controller = @import("system/Controller.zig");

mutex: std.Io.Mutex = .init,
gpa: std.mem.Allocator,
entities: std.AutoArrayHashMapUnmanaged(shared.entity.Id, Entity) = .empty,
teleporter_bosses: shared.CappedList(shared.entity.Id) = .empty,
pending_spawn: shared.CappedList(shared.net.SpawnEntity) = .empty,
pending_despawn: shared.CappedList(shared.entity.Id) = .empty,
pending_stats: shared.CappedList(shared.net.UpdateStat) = .empty,
pending_inventory: shared.CappedList(shared.net.UpdateInventory) = .empty,
attack_events: shared.CappedList(shared.entity.Id) = .empty,
camera: Camera = .{},
controller: Controller = .{},
teleporter_id: shared.entity.Id = .none,
player_id: shared.entity.Id = .none,
planet_radius: f32 = 0,
stage: u32 = 0,

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

pub fn init(gpa: std.mem.Allocator) !@This() {
    return .{
        .gpa = gpa,
        .teleporter_bosses = try .initCapacity(gpa, shared.max_entities),
        .pending_spawn = try .initCapacity(gpa, shared.max_entities),
        .pending_despawn = try .initCapacity(gpa, shared.max_entities),
        .pending_stats = try .initCapacity(gpa, shared.max_entities),
        .pending_inventory = try .initCapacity(gpa, shared.max_entities),
        .attack_events = try .initCapacity(gpa, shared.max_entities),
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
    self.attack_events.deinit(self.gpa);
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
