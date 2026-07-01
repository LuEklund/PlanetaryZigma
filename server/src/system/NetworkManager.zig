const std = @import("std");
const shared = @import("shared");
const system = @import("../system.zig");
const Spawner = @import("Spawner.zig");
const tracy = @import("ztracy");
const Info = system.Info;
const nz = shared.numz;

pub const Client = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    steam_server: *shared.SteamNet.Server,
    conn: shared.SteamNet.Conn,
    name: []const u8 = "",
    entity_id: u32 = 0,
    needs_full_sync: bool = true,
    command_queue: shared.net.PacketQueue(shared.net.ClientPacket) = .{},

    pub fn sendCommand(self: *@This(), writer: *std.Io.Writer, command: shared.net.ServerPacket, flags: shared.SteamNet.SendFlags) !void {
        writer.end = 0;
        try shared.net.write(shared.net.ServerPacket, command, writer);
        // std.log.debug("len: {d}", .{writer.buffered().len});

        try self.steam_server.packets.pushOutgoing(self.gpa, self.conn, writer.buffered(), flags);
    }

    pub fn deinit(self: *@This()) !void {
        if (self.name.len != 0) self.gpa.free(self.name);
        try self.command_queue.deinit(self.gpa, self.io);
    }
};

gpa: std.mem.Allocator,
io: std.Io,
steam_server: *shared.SteamNet.Server,
clients: std.AutoHashMap(shared.SteamNet.Conn, Client),
last_motions: std.AutoHashMap(u32, shared.net.UpdateMotion),
pending_motions: std.ArrayList(shared.net.UpdateMotion) = .empty,
pending_stats: std.ArrayList(shared.net.UpdateStat) = .empty,
pending_inventory: std.ArrayList(shared.net.UpdateInventory) = .empty,
pending_spawn: std.ArrayList(u32) = .empty,
pending_despawn: std.ArrayList(u32) = .empty,
pending_animatoin_state: std.ArrayList(struct { id: u32, state: shared.Entity.State }) = .empty,
pending_events: std.ArrayList(shared.net.Event) = .empty,

pub fn init(self: *@This(), gpa: std.mem.Allocator, io: std.Io, net: *shared.SteamNet.Server) !void {
    var last_motions: std.AutoHashMap(u32, shared.net.UpdateMotion) = .init(gpa);
    try last_motions.ensureTotalCapacity(system.World.max_entities);
    self.* = .{
        .gpa = gpa,
        .io = io,
        .steam_server = net,
        .clients = .init(gpa),
        .pending_stats = try .initCapacity(gpa, 4096),
        .pending_animatoin_state = try .initCapacity(gpa, 1024),
        .pending_inventory = try .initCapacity(gpa, 1024),
        .pending_events = try .initCapacity(gpa, 64),
        .last_motions = last_motions,
    };
}

pub fn deinit(self: *@This()) !void {
    var it = self.clients.iterator();
    while (it.next()) |pair| try pair.value_ptr.deinit();
    self.clients.deinit();
    self.pending_animatoin_state.deinit(self.gpa);
    self.pending_spawn.deinit(self.gpa);
    self.pending_despawn.deinit(self.gpa);
    self.pending_motions.deinit(self.gpa);
    self.pending_inventory.deinit(self.gpa);
    self.last_motions.deinit();
}

pub fn reload(self: *@This(), pre_reload: bool) !void {
    _ = self;
    _ = pre_reload;
    // Steam connection state lives in main.zig and survives reload; nothing to
    // tear down or rebuild here.
}

pub fn update(self: *@This(), info: *const Info, spawner: *Spawner) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    const world = info.world;

    try self.steam_server.packet_mutex.lock(self.io);
    // std.log.debug("cmd coint: {d}", .{self.steam_server.packets.incoming.items.len});
    // 1. Drain Steam lifecycle events into client map.
    for (self.steam_server.packets.events.items) |ev| switch (ev) {
        .connected => |conn| {
            const gop = try self.clients.getOrPut(conn);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{
                    .gpa = self.gpa,
                    .io = self.io,
                    .steam_server = self.steam_server,
                    .conn = conn,
                };
                std.log.debug("client connected: conn={d}", .{conn});
            }
        },
        .disconnected => |conn| {
            if (self.clients.getPtr(conn)) |client| {
                if (client.entity_id != 0) spawner.depspawn(client.entity_id);
                try client.deinit();
                _ = self.clients.remove(conn);
                std.log.debug("client disconnected: conn={d}", .{conn});
            }
        },
    };
    self.steam_server.packets.events.clearRetainingCapacity();

    // 2. Drain incoming bytes into the matching client's command queue.
    for (self.steam_server.packets.incoming.items) |*msg| {
        const client = self.clients.getPtr(msg.conn) orelse continue;
        var msg_reader: std.Io.Reader = .fixed(&msg.bytes);
        const reader = &msg_reader;
        const parsed = shared.net.parse(shared.net.ClientPacket, reader) catch |err| {
            std.log.err("parse packet: {s}", .{@errorName(err)});
            continue;
        };
        try client.command_queue.commands.append(self.gpa, parsed);
    }
    self.steam_server.packets.incoming.clearRetainingCapacity();

    // 3. Process per-client command queues.
    var fixed_writer_buffer: [1024]u8 = undefined;
    var fix_writer: std.Io.Writer = .fixed(&fixed_writer_buffer);
    const writer = &fix_writer;

    var it = self.clients.iterator();
    while (it.next()) |pair| {
        const client = pair.value_ptr;
        for (client.command_queue.commands.items) |command| {
            switch (command) {
                .connect => |connect| {
                    if (client.name.len == 0) client.name = try self.gpa.dupe(u8, connect.name);
                    const new_player_entity = try spawner.spawn(.{
                        .kind = .player,
                        .transform = .{ .position = .{ 0, 100, 0 } },
                        .collider = .{
                            .shape = .{ .primitive = .{ .capsule = .{ .half_heigth = 0.3, .radius = 0.5 } } },
                            .motion_type = .dynamic,
                            .object_layer = .moving,
                        },
                        .health = .{ .current = 100, .max = 100 },
                        .camera = .{ .transform = .{ .position = .{ 0, 0, 100 } } },
                        .flags = .{ .invinsible = true },
                    });
                    client.entity_id = new_player_entity.id;
                    info.world.players.appendAssumeCapacity(client.entity_id);

                    try client.sendCommand(
                        writer,
                        .{ .acknowledge = .{ .id = client.entity_id, .tick = info.tick } },
                        .reliable,
                    );
                    if (info.world.getPtr(info.world.teleporter_id)) |entity| {
                        if (entity.teleporter.active) {
                            try client.sendCommand(writer, .{
                                .update_event = .teleport_start,
                            }, .reliable);
                        }
                    }
                    std.log.debug("PLAYER SPAWN entity_id={d} body_id={any}", .{
                        client.entity_id,
                        new_player_entity.collider.body_id,
                    });
                },
                .disconnect => {
                    if (client.entity_id == 0) continue;
                    spawner.depspawn(client.entity_id);
                    std.log.debug("player disconnect", .{});
                },
                .input => {
                    if (world.getPtr(client.entity_id)) |entity| {
                        entity.controller.input = command.input;
                    }
                },
            }
        }
        client.command_queue.commands.clearRetainingCapacity();
    }

    // 4. Push outbound state to every active client.
    self.pending_motions.clearRetainingCapacity();
    for (world.entities.values()) |*entity| {
        if (shared.Entity.hasCollider(entity.kind) and entity.collider.motion_type == .static) continue;

        const position = entity.transform.position;
        const rotation = entity.transform.rotation.toVec();

        const entry = try self.last_motions.getOrPut(entity.id);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{
                .id = entity.id,
                .position = position,
                .velocity = entity.velocity,
                .rotation = rotation,
                .tick = info.tick,
            };
            try self.pending_motions.append(self.gpa, entry.value_ptr.*);
            continue;
        }

        const last_motion = entry.value_ptr;
        const elapsed = @as(f32, @floatFromInt(info.tick - last_motion.tick)) * shared.tick_seconds;
        const predicted = last_motion.position + nz.vec.scale(last_motion.velocity, elapsed);
        const position_drift = nz.vec.length(position - predicted);
        const rotation_drift = 1.0 - @abs(nz.vec.dot(rotation, last_motion.rotation));
        const velocity_drift = nz.vec.length(entity.velocity - last_motion.velocity);

        if (position_drift > 0.25 or rotation_drift > 0.01 or velocity_drift > 1.0) {
            last_motion.* = .{
                .id = entity.id,
                .position = position,
                .velocity = entity.velocity,
                .rotation = rotation,
                .tick = info.tick,
            };
            try self.pending_motions.append(self.gpa, last_motion.*);
        }
    }
    it = self.clients.iterator();
    while (it.next()) |pair| {
        const client = pair.value_ptr;

        try client.sendCommand(writer, .{ .server_tick = info.tick }, .unreliable_no_delay);

        if (world.getPtr(client.entity_id)) |player_entity| {
            client.needs_full_sync = client.needs_full_sync or player_entity.controller.input.keys.r;
        }

        // spawns
        if (client.needs_full_sync) {
            std.log.debug("FULL SYNC", .{});
            for (world.entities.values()) |*entity| {
                std.log.debug("sent id {d}", .{entity.id});
                try client.sendCommand(writer, .{ .spawn_entity = self.spawnPacket(info, entity) }, .reliable);
            }
            var motion_it = self.last_motions.valueIterator();
            while (motion_it.next()) |motion| {
                try client.sendCommand(writer, .{ .update_motion = motion.* }, .reliable);
            }
            client.needs_full_sync = false;
        } else {
            for (self.pending_spawn.items) |entity_id| {
                const entity = world.getPtr(entity_id) orelse continue;
                try client.sendCommand(writer, .{ .spawn_entity = self.spawnPacket(info, entity) }, .reliable);
            }
            for (self.pending_motions.items) |motion| {
                try client.sendCommand(writer, .{ .update_motion = motion }, .unreliable_no_delay);
            }
        }
        // despawns
        for (self.pending_despawn.items) |id| {
            try client.sendCommand(
                writer,
                .{
                    .despawn_entity = .{
                        .id = id,
                    },
                },
                .reliable,
            );
        }
        // stats
        for (self.pending_stats.items) |update_stat| {
            try client.sendCommand(writer, .{
                .update_stat = update_stat,
            }, .reliable);
        }
        for (self.pending_inventory.items) |update_inventory| {
            try client.sendCommand(writer, .{
                .update_inventory = update_inventory,
            }, .reliable);
        }

        // animations states
        for (self.pending_animatoin_state.items) |entry| {
            try client.sendCommand(writer, .{
                .update_animation_state = .{
                    .id = @intCast(entry.id),
                    .state = entry.state,
                },
            }, .reliable);
        }
        // events
        for (self.pending_events.items) |event| {
            try client.sendCommand(writer, .{
                .update_event = event,
            }, .reliable);
        }
    }
    // std.log.debug("cmd size {d}", .{self.steam_server.packets.outgoing.items.len});
    for (self.pending_despawn.items) |id| _ = self.last_motions.remove(id);
    self.pending_despawn.clearRetainingCapacity();
    self.pending_spawn.clearRetainingCapacity();
    self.pending_stats.clearRetainingCapacity();
    self.pending_animatoin_state.clearRetainingCapacity();
    self.pending_events.clearRetainingCapacity();
    self.pending_inventory.clearRetainingCapacity();
    self.steam_server.packet_mutex.unlock(self.io);
}

fn spawnPacket(self: *@This(), info: *const Info, entity: *const system.Entity) shared.net.SpawnEntity {
    if (shared.Entity.hasHealth(entity.kind)) {
        self.pending_stats.appendAssumeCapacity(.{
            .id = entity.id,
            .amount = .{ .set_max_health = @floatCast(entity.health.max) },
        });
        self.pending_stats.appendAssumeCapacity(.{
            .id = entity.id,
            .amount = .{ .set_health = @floatCast(entity.health.current) },
        });
    }
    return .{
        .id = entity.id,
        .kind = entity.kind,
        .position = entity.transform.position,
        .rotation = entity.transform.rotation.toVec(),
        .data = switch (entity.kind) {
            .planet => .{ .planet_size = info.world.planet_size },
            .bullet => .{ .bullet_velocity = entity.bullet.velocity },
            .skelly, .wizard => if (entity.flags.is_teleporter_boss) .is_teleporter_boss else .none,
            .unknown, .player, .teleporter, .health_item, .speed_item, .damage_item, .attack_speed_item => .none,
        },
    };
}
