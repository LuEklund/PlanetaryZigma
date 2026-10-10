const Network = @This();

const std = @import("std");
const shared = @import("shared");
const system = @import("../System.zig");
const stage = @import("../gameplay/stage.zig");
const lobby = @import("../gameplay/lobby.zig");
const commands = @import("../gameplay/commands.zig");
const tracy = @import("ztracy");
const World = system.World;
const nz = shared.numz;

gpa: std.mem.Allocator,
io: std.Io,
steam_server: shared.SteamNet.Server,
clients: std.AutoHashMap(shared.SteamNet.Connection, Client),
last_motions: std.AutoHashMap(shared.entity.Id, shared.net.UpdateMotion),
pending_motions: std.ArrayList(shared.net.UpdateMotion),
session_metadata_dirty: bool,

pub const WireStatus = enum {
    running,
    host_left,
    host_timeout,
};

pub const Client = struct {
    conn: shared.SteamNet.Connection,
    name: []const u8 = "",
    entity_id: shared.entity.Id = .none,
    needs_full_sync: bool = true,
    command_queue: shared.net.PacketQueue(shared.net.ClientPacket) = .{},

    pub fn deinit(self: *Client, gpa: std.mem.Allocator, io: std.Io) !void {
        if (self.name.len != 0) gpa.free(self.name);
        clearClientCommands(gpa, self);
        try self.command_queue.deinit(gpa, io);
    }
};

const Outbox = struct {
    steam_server: *shared.SteamNet.Server,
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,

    fn send(
        outbox: Outbox,
        client: *const Client,
        command: shared.net.ServerPacket,
        flags: shared.SteamNet.SendFlags,
    ) !void {
        outbox.writer.end = 0;
        try shared.net.write(shared.net.ServerPacket, command, outbox.writer);
        try outbox.steam_server.packets.pushOutgoing(
            outbox.gpa,
            client.conn,
            outbox.writer.buffered(),
            flags,
        );
    }
};

pub fn init(
    self: *Network,
    gpa: std.mem.Allocator,
    io: std.Io,
    mode: shared.SteamNet.Server.Mode,
    host_steam_id: u64,
    log_connection_status: bool,
) !void {
    self.gpa = gpa;
    self.io = io;
    self.clients = .init(gpa);
    self.last_motions = .init(gpa);
    try self.last_motions.ensureTotalCapacity(shared.max_entities);
    self.pending_motions = .empty;
    self.session_metadata_dirty = true;
    try self.steam_server.init(gpa, io, .{
        .mode = mode,
        .host_steam_id = host_steam_id,
        .log_connection_status = log_connection_status,
    });
}

pub fn deinit(self: *Network) !void {
    var it = self.clients.iterator();
    while (it.next()) |pair| try pair.value_ptr.deinit(self.gpa, self.io);
    self.clients.deinit();
    self.pending_motions.deinit(self.gpa);
    self.last_motions.deinit();
    self.steam_server.deinit();
}

fn cloneClientPacket(
    gpa: std.mem.Allocator,
    packet: shared.net.ClientPacket,
) !shared.net.ClientPacket {
    return switch (packet) {
        .connect => |connect| .{ .connect = connect },
        .disconnect => .disconnect,
        .go_again => .go_again,
        .lobby => |lobby_command| .{ .lobby = lobby_command },
        .input => |input| .{ .input = input },
        .ping => |ping| .{ .ping = ping },
        .chat => |chat| chat: {
            const text = try gpa.dupe(u8, chat.text);
            break :chat .{ .chat = .{
                .text_len = @intCast(text.len),
                .text = text,
            } };
        },
    };
}

fn freeClientPacket(gpa: std.mem.Allocator, packet: *shared.net.ClientPacket) void {
    switch (packet.*) {
        .chat => |chat| if (chat.text.len != 0) gpa.free(chat.text),
        .connect, .disconnect, .input, .go_again, .lobby, .ping => {},
    }
}

fn clearClientCommands(gpa: std.mem.Allocator, client: *Client) void {
    for (client.command_queue.commands.items) |*command| {
        freeClientPacket(gpa, command);
    }
    client.command_queue.commands.clearRetainingCapacity();
}

pub fn update(self: *Network, world: *World) !WireStatus {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();

    try self.steam_server.packet_mutex.lock(self.io);
    defer self.steam_server.packet_mutex.unlock(self.io);

    try self.drainConnectionEvents(world);
    try self.queueIncomingPackets();

    var fixed_writer_buffer: [1024]u8 = undefined;
    var fixed_writer: std.Io.Writer = .fixed(&fixed_writer_buffer);
    const outbox: Outbox = .{
        .steam_server = &self.steam_server,
        .gpa = self.gpa,
        .writer = &fixed_writer,
    };

    var sync_all_clients = false;
    var clients = self.clients.iterator();
    while (clients.next()) |pair| {
        const client = pair.value_ptr;
        for (client.command_queue.commands.items) |command| {
            if (try self.applyCommand(world, outbox, client, command)) sync_all_clients = true;
        }
        clearClientCommands(self.gpa, client);
    }
    if (sync_all_clients) self.markAllClientsForFullSync();
    if (self.session_metadata_dirty) self.updateAdvertisedSession();

    try self.collectMotions(world);
    clients = self.clients.iterator();
    while (clients.next()) |pair| try self.sendFrame(world, outbox, pair.value_ptr);

    for (world.client_updates.items) |packet| switch (packet) {
        .despawn_entity => |despawn_entity| _ = self.last_motions.remove(despawn_entity.id),
        else => {},
    };
    world.client_updates.clearRetainingCapacity();
    world.spawned.clearRetainingCapacity();

    if (self.steam_server.host_state == .left) return .host_left;
    if (self.steam_server.host_state == .waiting and world.elapsed_time > 60) return .host_timeout;
    return .running;
}

fn drainConnectionEvents(self: *Network, world: *World) !void {
    defer self.steam_server.packets.events.clearRetainingCapacity();
    for (self.steam_server.packets.events.items) |event| switch (event) {
        .connected => |conn| {
            const entry = try self.clients.getOrPut(conn);
            if (entry.found_existing) continue;
            entry.value_ptr.* = .{ .conn = conn };
            std.log.info("client connected: conn={d}", .{conn});
        },
        .disconnected => |conn| {
            const client = self.clients.getPtr(conn) orelse continue;
            if (client.entity_id != .none) world.queueRemove(client.entity_id);
            try client.deinit(self.gpa, self.io);
            _ = self.clients.remove(conn);
            self.session_metadata_dirty = true;
            std.log.info("client disconnected: conn={d}", .{conn});
        },
    };
}

fn queueIncomingPackets(self: *Network) !void {
    defer self.steam_server.packets.incoming.clearRetainingCapacity();
    for (self.steam_server.packets.incoming.items) |*message| {
        const client = self.clients.getPtr(message.conn) orelse continue;
        var reader: std.Io.Reader = .fixed(message.slice());
        const parsed = shared.net.parse(shared.net.ClientPacket, &reader) catch |err| {
            std.log.err("parse packet: {s}", .{@errorName(err)});
            continue;
        };
        var queued_packet = try cloneClientPacket(self.gpa, parsed);
        errdefer freeClientPacket(self.gpa, &queued_packet);
        try client.command_queue.commands.append(self.gpa, queued_packet);
    }
}

/// Returns true when every client needs a full resync.
fn applyCommand(
    self: *Network,
    world: *World,
    outbox: Outbox,
    client: *Client,
    command: shared.net.ClientPacket,
) !bool {
    switch (command) {
        .connect => |request| return self.acceptConnect(world, outbox, client, request),
        .disconnect => {
            if (client.entity_id == .none) return false;
            world.queueRemove(client.entity_id);
            std.log.info("player disconnect", .{});
        },
        .input => |input| {
            const entity = world.getPtrRaw(client.entity_id) orelse return false;
            entity.controller.input = input;
        },
        .lobby => |lobby_command| {
            const player = world.getPtrRaw(client.entity_id) orelse return false;
            const is_host = client.conn == self.steam_server.host_conn;
            switch (lobby_command) {
                .survivor => |survivor| lobby.setSurvivor(world, player, survivor),
                .ready => |ready| lobby.setReady(world, player, ready),
                .difficulty => |setting| if (is_host) lobby.setDifficulty(world, setting),
            }
        },
        .ping => |ping| {
            if (client.entity_id == .none) return false;
            if (world.client_updates.unusedCapacitySlice().len == 0) return false;
            world.client_updates.appendAssumeCapacity(.{ .event = .{ .ping = .{
                .pinger = client.entity_id,
                .position = ping.position,
                .target = ping.target,
            } } });
        },
        .go_again => {
            if (client.conn == self.steam_server.host_conn) world.go_again_requested = true;
        },
        .chat => |chat| {
            if (client.entity_id == .none) return false;
            var text_buffer: [shared.max_chat_len]u8 = undefined;
            const text = sanitizeText(&text_buffer, chat.text);
            if (text.len == 0) return false;
            if (text[0] == commands.prefix) return runCommand(world, outbox, client, text);
            std.log.debug("chat {s}: {s}", .{ client.name, text });
            try self.broadcastChat(outbox, client.entity_id, text);
        },
    }
    return false;
}

fn acceptConnect(
    self: *Network,
    world: *World,
    outbox: Outbox,
    client: *Client,
    request: shared.net.Connect,
) !bool {
    if (request.protocol_version != shared.net.protocol_version) {
        std.log.warn("rejecting client conn={d}: protocol {d} != server {d}", .{
            client.conn,
            request.protocol_version,
            shared.net.protocol_version,
        });
        _ = self.steam_server.socket.CloseConnection(
            client.conn,
            0,
            "protocol version mismatch",
            false,
        );
        return false;
    }
    const renamed = try self.rename(client, request.player_name.slice());
    if (client.entity_id != .none) return renamed;
    if (world.players.items.len >= shared.max_players) {
        std.log.warn(
            "rejecting client conn={d}: server full ({d} players)",
            .{ client.conn, world.players.items.len },
        );
        _ = self.steam_server.socket.CloseConnection(client.conn, 0, "server full", false);
        return false;
    }
    try self.spawnPlayer(world, outbox, client, request.survivor);
    return false;
}

/// Returns true when an already spawned player changed name.
fn rename(self: *Network, client: *Client, raw_name: []const u8) !bool {
    var name_buffer: [shared.max_player_name_len]u8 = undefined;
    const name = sanitizeText(&name_buffer, raw_name);
    const display_name = if (name.len == 0) shared.default_player_name else name;
    if (std.mem.eql(u8, client.name, display_name)) return false;
    if (client.name.len != 0) self.gpa.free(client.name);
    client.name = try self.gpa.dupe(u8, display_name);
    self.session_metadata_dirty = true;
    return client.entity_id != .none;
}

fn spawnPlayer(
    self: *Network,
    world: *World,
    outbox: Outbox,
    client: *Client,
    survivor: shared.Survivor.Kind,
) !void {
    const player = world.spawn(.{
        .kind = .player,
        .survivor = survivor,
        .transform = .{ .position = stage.playerSpawnPosition(world) },
        .camera = .{ .transform = .{ .position = .{ 0, 0, 100 } } },
    }) catch return;
    client.entity_id = player.id;
    world.players.appendAssumeCapacity(client.entity_id);
    self.session_metadata_dirty = true;

    try outbox.send(
        client,
        .{ .acknowledge = .{ .id = client.entity_id, .tick = world.tick } },
        .reliable,
    );
    try outbox.send(client, .{ .event = .{ .new_stage = world.stage } }, .reliable);
    const teleporter_active = if (world.getPtr(
        world.teleporter_id,
    )) |entity| entity.teleporter.state == .active else false;
    if (teleporter_active) try outbox.send(client, .{ .event = .teleport_start }, .reliable);
    std.log.info("PLAYER SPAWN entity_id={d} name=\"{s}\"", .{ client.entity_id, client.name });
}

fn collectMotions(self: *Network, world: *World) !void {
    self.pending_motions.clearRetainingCapacity();
    for (world.entities.values()) |*entity| {
        if (!tracksMotion(entity)) continue;
        const current: shared.net.UpdateMotion = .{
            .id = entity.id,
            .position = entity.transform.position,
            .velocity = entity.replicated_velocity,
            .rotation = entity.transform.rotation.toVec(),
            .tick = world.tick,
        };
        const entry = try self.last_motions.getOrPut(entity.id);
        if (!entry.found_existing) {
            entry.value_ptr.* = current;
            continue;
        }
        if (!drifted(entry.value_ptr.*, current)) continue;
        entry.value_ptr.* = current;
        try self.pending_motions.append(self.gpa, current);
    }
}

fn drifted(last: shared.net.UpdateMotion, current: shared.net.UpdateMotion) bool {
    const elapsed = @as(f32, @floatFromInt(current.tick - last.tick)) * shared.tick_seconds;
    const predicted = last.position + nz.vec.scale(last.velocity, elapsed);
    const position_drift = nz.vec.length(current.position - predicted);
    const rotation_drift = 1.0 - @abs(nz.vec.dot(current.rotation, last.rotation));
    const velocity_drift = nz.vec.length(current.velocity - last.velocity);
    return position_drift > 0.25 or rotation_drift > 0.01 or velocity_drift > 1.0;
}

fn sendFrame(self: *Network, world: *World, outbox: Outbox, client: *Client) !void {
    if (client.entity_id == .none) return;
    try outbox.send(client, .{ .server_tick = world.tick }, .unreliable_no_delay);
    if (world.getPtrRaw(client.entity_id)) |player| {
        client.needs_full_sync = client.needs_full_sync or player.controller.resync_requested;
        player.controller.resync_requested = false;
    }

    const full_sync = client.needs_full_sync;
    if (full_sync) {
        try self.sendFullSync(world, outbox, client);
    } else for (self.pending_motions.items) |motion| {
        try outbox.send(client, .{ .motion = motion }, .unreliable_no_delay);
    }

    for (world.client_updates.items) |packet| {
        if (full_sync and packet == .spawn_planet) continue;
        try outbox.send(client, packet, .reliable);
    }
    if (full_sync) return;
    for (world.spawned.items) |id| {
        const entity = world.getPtr(id) orelse continue;
        try self.sendSpawn(world, outbox, client, entity);
    }
}

fn sendFullSync(self: *Network, world: *World, outbox: Outbox, client: *Client) !void {
    std.log.debug("FULL SYNC", .{});
    try outbox.send(client, .{ .spawn_planet = world.planet.planet_radius }, .reliable);
    try outbox.send(client, .{ .lobby_difficulty = world.difficulty_setting }, .reliable);
    for (world.entities.values()) |*entity| {
        try self.sendSpawn(world, outbox, client, entity);
        if (entity.kind == .player) try outbox.send(client, .{ .lobby_player = .{
            .id = entity.id,
            .survivor = entity.survivor,
            .ready = entity.ready,
        } }, .reliable);
        if (tracksMotion(entity)) try outbox.send(
            client,
            .{ .motion = motionPacket(world, entity) },
            .reliable,
        );
    }
    client.needs_full_sync = false;
}

fn sendSpawn(
    self: *Network,
    world: *World,
    outbox: Outbox,
    client: *const Client,
    entity: *const system.Entity,
) !void {
    const packet = spawnPacket(world, entity, self.nameForEntity(entity.id));
    try outbox.send(client, .{ .spawn_entity = packet }, .reliable);
    try sendHealth(outbox, client, entity);
    try sendInventory(outbox, client, entity);
}

fn sendHealth(outbox: Outbox, client: *const Client, entity: *const system.Entity) !void {
    if (entity.max_health <= 0) return;
    try outbox.send(
        client,
        .{
            .health = .{
                .id = entity.id,
                .source = .none,
                .amount = .{ .set_max = @floatCast(entity.max_health) },
            },
        },
        .reliable,
    );
    try outbox.send(
        client,
        .{
            .health = .{
                .id = entity.id,
                .source = .none,
                .amount = .{ .set_current = @floatCast(entity.health) },
            },
        },
        .reliable,
    );
}

fn tracksMotion(entity: *const system.Entity) bool {
    if (entity.flags.is_dead) return false;
    const kind_collider = entity.kind.collider() orelse return true;
    return kind_collider.motion != .static;
}

fn motionPacket(world: *World, entity: *const system.Entity) shared.net.UpdateMotion {
    return .{
        .id = entity.id,
        .position = entity.transform.position,
        .velocity = entity.replicated_velocity,
        .rotation = entity.transform.rotation.toVec(),
        .tick = world.tick,
    };
}

fn sendInventory(outbox: Outbox, client: *const Client, entity: *const system.Entity) !void {
    if (entity.kind != .player) return;
    for (std.enums.values(shared.Item.Kind)) |item_kind| {
        const count = entity.inventory.get(item_kind);
        if (count > 0) try outbox.send(
            client,
            .{ .inventory = .{ .id = entity.id, .item_kind = item_kind, .set = count } },
            .reliable,
        );
    }
}

fn spawnPacket(
    world: *World,
    entity: *const system.Entity,
    player_name: []const u8,
) shared.net.SpawnEntity {
    return .{
        .id = entity.id,
        .kind = entity.kind,
        .position = entity.transform.position,
        .rotation = entity.transform.rotation.toVec(),
        .velocity = entity.replicated_velocity,
        .tick = world.tick,
        .currency = entity.currency,
        .elite = entity.elite,
        .survivor = entity.survivor,
        .data = switch (entity.kind) {
            .enemy => if (entity.flags.is_teleporter_boss) .is_teleporter_boss else .none,
            .player => .{ .player_name = .copy(player_name) },
            .item_pickup => .{ .item = entity.item.? },
            .unknown, .projectile_heal, .projectile_cube, .projectile_rocket, .teleporter, .lootbox, .platform, .target_dummy => .none,
        },
    };
}

fn nameForEntity(self: *Network, entity_id: shared.entity.Id) []const u8 {
    var it = self.clients.valueIterator();
    while (it.next()) |client| {
        if (client.entity_id == entity_id and client.name.len != 0) return client.name;
    }
    return shared.default_player_name;
}

fn markAllClientsForFullSync(self: *Network) void {
    var it = self.clients.valueIterator();
    while (it.next()) |client| {
        client.needs_full_sync = true;
    }
}

fn runCommand(world: *World, outbox: Outbox, client: *Client, line: []const u8) !bool {
    const player = world.getPtrRaw(client.entity_id) orelse return false;
    var reply_buffer: [16 * shared.max_chat_len]u8 = undefined;
    const reply = commands.run(world, player, line, &reply_buffer);
    std.log.info("command {s}: {s} -> {s}", .{ client.name, line, reply });
    var lines = std.mem.tokenizeScalar(u8, reply, '\n');
    while (lines.next()) |reply_line| {
        var rest = reply_line;
        while (rest.len > 0) {
            const piece = rest[0..@min(rest.len, shared.max_chat_len)];
            rest = rest[piece.len..];
            try outbox.send(client, .{ .chat_message = .{
                .id = .none,
                .text_len = @intCast(piece.len),
                .text = piece,
            } }, .reliable);
        }
    }
    return false;
}

fn broadcastChat(
    self: *Network,
    outbox: Outbox,
    sender_id: shared.entity.Id,
    text: []const u8,
) !void {
    var it = self.clients.valueIterator();
    while (it.next()) |client| {
        if (client.entity_id == .none) continue;
        try outbox.send(client, .{ .chat_message = .{
            .id = sender_id,
            .text_len = @intCast(text.len),
            .text = text,
        } }, .reliable);
    }
}

fn updateAdvertisedSession(self: *Network) void {
    var player_names: [shared.max_players][]const u8 = undefined;
    var player_count: usize = 0;
    var host_name: []const u8 = "";

    var it = self.clients.valueIterator();
    while (it.next()) |client| {
        if (client.entity_id == .none or client.name.len == 0) continue;
        if (client.conn == self.steam_server.host_conn) host_name = client.name;
        if (player_count < player_names.len) {
            player_names[player_count] = client.name;
            player_count += 1;
        }
    }

    if (host_name.len == 0 and player_count != 0) host_name = player_names[0];
    self.steam_server.updateSessionMetadata(
        shared.max_players,
        shared.net.protocol_version,
        host_name,
        player_names[0..player_count],
    );
    self.session_metadata_dirty = false;
}

fn sanitizeText(buffer: []u8, raw: []const u8) []const u8 {
    var len: usize = 0;
    for (std.mem.trim(u8, raw, " \t\r\n")) |char| {
        if (len >= buffer.len) break;
        if (char < 32 or char == 127) continue;
        buffer[len] = char;
        len += 1;
    }
    return buffer[0..len];
}
