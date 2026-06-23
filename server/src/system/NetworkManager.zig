const std = @import("std");
const shared = @import("shared");
const system = @import("../system.zig");
const Spawner = @import("Spawner.zig");
const tracy = @import("ztracy");
const Info = system.Info;

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
pending_add_health: std.ArrayList(struct { id: u32, amount: f32 }) = .empty,
pending_spawn: std.ArrayList(struct { kind: shared.Entity.Kind, id: u32 }) = .empty,
pending_despawn: std.ArrayList(u32) = .empty,
pending_state: std.ArrayList(struct { id: u32, state: shared.Entity.State }) = .empty,

pub fn init(self: *@This(), gpa: std.mem.Allocator, io: std.Io, net: *shared.SteamNet.Server) !void {
    self.* = .{
        .gpa = gpa,
        .io = io,
        .steam_server = net,
        .clients = .init(gpa),
        .pending_add_health = try .initCapacity(gpa, 4096),
        .pending_state = try .initCapacity(gpa, 1024),
    };
}

pub fn deinit(self: *@This()) !void {
    var it = self.clients.iterator();
    while (it.next()) |pair| try pair.value_ptr.deinit();
    self.clients.deinit();
    self.pending_state.deinit(self.gpa);
    self.pending_spawn.deinit(self.gpa);
    self.pending_despawn.deinit(self.gpa);
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
                            .shape = .{ .primitive = .{ .capsule = .{ .size = 1 } } },
                            .motion_type = .dynamic,
                            .object_layer = .moving,
                        },
                        .health = .{ .current = 100, .max = 100 },
                        .camera = .{ .transform = .{ .position = .{ 0, 0, 100 } } },
                        .flags = .{
                            .transform = true,
                            .collider = true,
                            .controller = true,
                            .camera = true,
                            .health = true,
                            .invinsible = true,
                        },
                    });
                    client.entity_id = new_player_entity.id;
                    info.world.players.appendAssumeCapacity(client.entity_id);
                    try client.sendCommand(writer, .{ .acknowledge = .{ .id = client.entity_id } }, .reliable);
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
    it = self.clients.iterator();
    while (it.next()) |pair| {
        const client = pair.value_ptr;

        // camera
        if (world.getPtr(client.entity_id)) |player_entity| {
            const camera = player_entity.camera;
            client.needs_full_sync = client.needs_full_sync or player_entity.controller.input.r;
            try client.sendCommand(writer, .{ .update_camera_rotation = .{
                .position = camera.transform.position,
                .rotation = camera.transform.rotation.toVec(),
                .id = client.entity_id,
            } }, .unreliable_no_delay);
        }

        // spawns
        if (client.needs_full_sync) {
            std.log.debug("FULL SYNC", .{});
            for (world.entities.values()) |*entity| {
                if (!entity.flags.transform) continue;
                std.log.debug("sent id {d}", .{entity.id});
                try client.sendCommand(writer, .{ .spawn_entity = spawnPacket(entity) }, .reliable);
            }
            client.needs_full_sync = false;
        } else {
            for (self.pending_spawn.items) |entry| {
                const entity = world.getPtr(entry.id) orelse continue;
                try client.sendCommand(writer, .{ .spawn_entity = spawnPacket(entity) }, .reliable);
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
        // health
        for (self.pending_add_health.items) |entry| {
            try client.sendCommand(writer, .{
                .add_health = .{
                    .id = @intCast(entry.id),
                    .amount = @floatCast(entry.amount),
                },
            }, .reliable);
        }
        // states
        for (self.pending_state.items) |entry| {
            std.log.debug("send id {d} : state {t}", .{ entry.id, entry.state });
            try client.sendCommand(writer, .{
                .update_state = .{
                    .id = @intCast(entry.id),
                    .state = entry.state,
                },
            }, .reliable);
        }
        // transforms
        for (world.entities.values()) |*entity| {
            if (!entity.flags.transform) continue;
            if (entity.flags.bullet) continue; // client simulates bullets from spawn pos+vel
            try client.sendCommand(writer, .{ .update_transform = .{
                .id = @intCast(entity.id),
                .position = @floatCast(entity.transform.position),
                .rotation = @floatCast(entity.transform.rotation.toVec()),
            } }, .unreliable_no_delay);
        }
    }
    // std.log.debug("cmd size {d}", .{self.steam_server.packets.outgoing.items.len});
    self.pending_despawn.clearRetainingCapacity();
    self.pending_spawn.clearRetainingCapacity();
    self.pending_add_health.clearRetainingCapacity();
    self.pending_state.clearRetainingCapacity();
    self.steam_server.packet_mutex.unlock(self.io);
}

fn spawnPacket(entity: *const system.Entity) shared.net.SpawnEntity {
    var data: [4]u8 = @splat(0);
    var velocity: @Vector(3, f32) = @splat(0);
    switch (entity.kind) {
        .planet => data = @bitCast(entity.planet),
        .bullet => velocity = entity.bullet.velocity,
        else => {},
    }
    return .{
        .id = entity.id,
        .kind = entity.kind,
        .position = entity.transform.position,
        .velocity = velocity,
        .data = data,
    };
}
