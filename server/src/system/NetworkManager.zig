const std = @import("std");
const shared = @import("shared");
const system = @import("../system.zig");
const tracy = @import("ztracy");
const Info = system.Info;
const nz = shared.numz;

gpa: std.mem.Allocator,
io: std.Io,
steam_server: *shared.SteamNet.Server,
clients: std.AutoHashMap(shared.SteamNet.Conn, Client),
last_motions: std.AutoHashMap(shared.entity.Id, shared.net.UpdateMotion),
pending_motions: std.ArrayList(shared.net.UpdateMotion) = .empty,

pub const WireStatus = enum {
    running,
    host_left,
    host_timeout,
};

pub const Client = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    steam_server: *shared.SteamNet.Server,
    conn: shared.SteamNet.Conn,
    name: []const u8 = "",
    entity_id: shared.entity.Id = .none,
    needs_full_sync: bool = true,
    command_queue: shared.net.PacketQueue(shared.net.ClientPacket) = .{},

    pub fn sendCommand(self: *Client, writer: *std.Io.Writer, command: shared.net.ServerPacket, flags: shared.SteamNet.SendFlags) !void {
        writer.end = 0;
        try shared.net.write(shared.net.ServerPacket, command, writer);

        try self.steam_server.packets.pushOutgoing(self.gpa, self.conn, writer.buffered(), flags);
    }

    pub fn deinit(self: *Client) !void {
        if (self.name.len != 0) self.gpa.free(self.name);
        try self.command_queue.deinit(self.gpa, self.io);
    }
};

pub fn init(gpa: std.mem.Allocator, io: std.Io, net: *shared.SteamNet.Server) !@This() {
    var last_motions: std.AutoHashMap(shared.entity.Id, shared.net.UpdateMotion) = .init(gpa);
    try last_motions.ensureTotalCapacity(shared.max_entities);
    return .{
        .gpa = gpa,
        .io = io,
        .steam_server = net,
        .clients = .init(gpa),
        .last_motions = last_motions,
    };
}

pub fn deinit(self: *@This()) !void {
    var it = self.clients.iterator();
    while (it.next()) |pair| try pair.value_ptr.deinit();
    self.clients.deinit();
    self.pending_motions.deinit(self.gpa);
    self.last_motions.deinit();
}

pub fn reload(self: *@This(), pre_reload: bool) !void {
    _ = self;
    _ = pre_reload;
    // Steam connection state lives in main.zig and survives reload; nothing to
    // tear down or rebuild here.
}

pub fn update(self: *@This(), info: *const Info) !WireStatus {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    const world = info.world;

    try self.steam_server.packet_mutex.lock(self.io);
    defer self.steam_server.packet_mutex.unlock(self.io);

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
                if (client.entity_id != .none) world.queueDespawn(client.entity_id);
                try client.deinit();
                _ = self.clients.remove(conn);
                std.log.debug("client disconnected: conn={d}", .{conn});
            }
        },
    };
    self.steam_server.packets.events.clearRetainingCapacity();

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
                    const new_player_entity = world.spawn(.{
                        .kind = .player,
                        .transform = .{ .position = .{ 0, @as(f32, @floatFromInt(info.world.planet_radius)) + 10, 0 } },
                        .camera = .{ .transform = .{ .position = .{ 0, 0, 100 } } },
                    }) catch continue;

                    client.entity_id = new_player_entity.id;
                    info.world.players.append(client.entity_id);

                    try client.sendCommand(
                        writer,
                        .{ .acknowledge = .{ .id = client.entity_id, .tick = info.tick } },
                        .reliable,
                    );
                    try client.sendCommand(writer, .{ .update_event = .{ .new_stage = info.world.next_stage } }, .reliable);
                    if (info.world.getPtr(info.world.teleporter_id)) |entity| {
                        if (entity.teleporter.active) {
                            try client.sendCommand(writer, .{
                                .update_event = .teleport_start,
                            }, .reliable);
                        }
                    }
                    std.log.debug("PLAYER SPAWN entity_id={d}", .{client.entity_id});
                },
                .disconnect => {
                    if (client.entity_id == .none) continue;
                    world.queueDespawn(client.entity_id);
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

    self.pending_motions.clearRetainingCapacity();
    for (world.entities.values()) |*entity| {
        if (shared.entity.hasCollider(entity.kind) and entity.collider.motion_type == .static) continue;

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

        const did_full_sync = client.needs_full_sync;
        if (did_full_sync) {
            std.log.debug("FULL SYNC", .{});
            for (world.entities.values()) |*entity| {
                std.log.debug("sent id {d}", .{entity.id});
                try client.sendCommand(writer, .{ .spawn_entity = spawnPacket(info, entity) }, .reliable);
                try sendStats(client, writer, entity);
            }
            var motion_it = self.last_motions.valueIterator();
            while (motion_it.next()) |motion| {
                try client.sendCommand(writer, .{ .update_motion = motion.* }, .reliable);
            }
            client.needs_full_sync = false;
        } else {
            for (self.pending_motions.items) |motion| {
                try client.sendCommand(writer, .{ .update_motion = motion }, .unreliable_no_delay);
            }
        }

        for (world.outbox.items) |pending_update| switch (pending_update) {
            .spawned => |id| {
                if (did_full_sync) continue;
                const entity = world.getPtr(id) orelse continue;
                try client.sendCommand(writer, .{ .spawn_entity = spawnPacket(info, entity) }, .reliable);
                try sendStats(client, writer, entity);
            },
            .despawned => |id| {
                try client.sendCommand(writer, .{ .despawn_entity = .{ .id = id } }, .reliable);
            },
            .stat => |update_stat| {
                try client.sendCommand(writer, .{ .update_stat = update_stat }, .reliable);
            },
            .inventory => |update_inventory| {
                try client.sendCommand(writer, .{ .update_inventory = update_inventory }, .reliable);
            },
            .event => |event| {
                try client.sendCommand(writer, .{ .update_event = event }, .reliable);
            },
        };
    }
    for (world.outbox.items) |pending_update| switch (pending_update) {
        .despawned => |id| _ = self.last_motions.remove(id),
        else => {},
    };
    world.outbox.clearRetainingCapacity();

    if (self.steam_server.host_state == .left) return .host_left;
    if (self.steam_server.host_state == .waiting and info.elapsed_time > 60) return .host_timeout;
    return .running;
}

fn sendStats(client: *Client, writer: *std.Io.Writer, entity: *const system.Entity) !void {
    if (!entity.kind.hasHealth()) return;
    for (std.enums.values(shared.Stat.Kind)) |stat_kind| {
        const stat = entity.stats.get(stat_kind);
        try client.sendCommand(writer, .{ .update_stat = .{ .id = entity.id, .stat_kind = stat_kind, .amount = .{ .set_max = @floatCast(stat.max) } } }, .reliable);
        try client.sendCommand(writer, .{ .update_stat = .{ .id = entity.id, .stat_kind = stat_kind, .amount = .{ .set_current = @floatCast(stat.current) } } }, .reliable);
    }
}

fn spawnPacket(info: *const Info, entity: *const system.Entity) shared.net.SpawnEntity {
    return .{
        .id = entity.id,
        .kind = entity.kind,
        .position = entity.transform.position,
        .rotation = entity.transform.rotation.toVec(),
        .velocity = entity.velocity,
        .tick = info.tick,
        .data = switch (entity.kind) {
            .planet => .{ .planet_radius = info.world.planet_radius },
            .enemy => if (entity.flags.is_teleporter_boss) .is_teleporter_boss else .none,
            .unknown, .bullet, .player, .teleporter, .item => .none,
        },
    };
}
