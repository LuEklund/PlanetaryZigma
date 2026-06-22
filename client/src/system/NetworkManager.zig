const std = @import("std");
const shared = @import("shared");
const tracy = @import("ztracy");
const Client = shared.SteamNet.Client;
const system = @import("../system.zig");
const World = system.World;
const Spawner = @import("Spawner.zig");
const Info = system.Info;
const nz = shared.numz;
const SkeletonAnimation = @import("../Renderer/Vulkan/SkeletonAnimation.zig");
const ServerList = struct {
    servers: [8]Client.ServerInfo = undefined,
    count: usize = 0,
    refresh: bool = true,
};

gpa: std.mem.Allocator,
io: std.Io,
steam_client: *Client,
spawner: *Spawner,
/// Active connection to the server (0 = not yet connected). Filled in from
/// SteamNet.events on the first .connected event.
server_conn: shared.SteamNet.Conn = 0,
my_server_id: u32 = 0,
/// Whether we've sent the "connect" handshake on the current server_conn.
sent_connect: bool = false,
server_list: ServerList = .{},

pub fn init(
    self: *@This(),
    gpa: std.mem.Allocator,
    io: std.Io,
    net: *shared.SteamNet.Client,
    spawner: *Spawner,
) !void {
    self.* = .{
        .gpa = gpa,
        .io = io,
        .steam_client = net,
        .spawner = spawner,
    };
}

pub fn deinit(self: *@This()) void {
    _ = self;
}

fn sendConnect(self: *@This()) !void {
    const name = "lucas";
    const cmd: shared.net.ClientPacket = .{ .connect = .{ .name_len = name.len, .name = name } };
    try self.sendCommand(cmd, .reliable);
}

pub fn sendCommand(self: *@This(), command: shared.net.ClientPacket, flags: shared.SteamNet.SendFlags) !void {
    if (self.server_conn == 0) return;
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try shared.net.write(shared.net.ClientPacket, command, &w);
    // std.log.debug("len: {d}", .{w.buffered().len});
    try self.steam_client.packets.pushOutgoing(self.gpa, self.server_conn, w.buffered(), flags);
}

pub fn update(
    self: *@This(),
    info: *const Info,
    skeletons: *std.AutoHashMap(u32, SkeletonAnimation),
) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    try self.steam_client.packet_mutex.lock(self.io);

    // 0. server list update.
    if (self.server_list.refresh == true and self.steam_client.browser.list.refresh_state == .idle) {
        self.steam_client.browser.list.refresh_state = .request;
    } else if (self.steam_client.browser.list.refresh_state == .done) {
        self.server_list.refresh = false;
        self.steam_client.browser.list.refresh_state = .idle;
        for (0..self.steam_client.browser.list.count) |i| {
            @memcpy(self.server_list.servers[i].name[0..], self.steam_client.browser.list.servers[i].name[0..]);
            self.server_list.servers[i].steam_id = self.steam_client.browser.list.servers[i].steam_id;
            _ = try std.fmt.bufPrint(&self.server_list.servers[i].id_str, "{d}", .{self.server_list.servers[i].steam_id});
        }
        self.server_list.count = self.steam_client.browser.list.count;
    }

    // 1. Drain lifecycle events.
    for (self.steam_client.packets.events.items) |ev| switch (ev) {
        .connected => |conn| {
            self.server_conn = conn;
            self.sent_connect = false;
        },
        .disconnected => |conn| {
            if (self.server_conn == conn) {
                self.server_conn = 0;
                self.sent_connect = false;
            }
        },
    };
    self.steam_client.packets.events.clearRetainingCapacity();

    // 2. Handshake once per fresh connection.
    if (self.server_conn != 0 and !self.sent_connect) {
        try self.sendConnect();
        self.sent_connect = true;
    }
    // 3. Send our input.
    if (self.server_conn != 0) {
        try self.sendCommand(.{ .input = info.world.camera.input_map }, .reliable);
        // std.log.debug("input_map: {any}", .{entity.camera.input_map});
        info.world.camera.input_map.mouse_wheel = 0;
    }
    // std.log.debug("cmd size {d}", .{self.steam_client.packets.incoming.items.len});
    // 4. Drain inbound commands.
    for (self.steam_client.packets.incoming.items) |*msg| {
        var msg_reader: std.Io.Reader = .fixed(&msg.bytes);
        const reader = &msg_reader;
        const parsed = shared.net.parse(shared.net.ServerPacket, reader) catch |err| {
            std.log.err("parse packet: {s}", .{@errorName(err)});
            continue;
        };
        try self.handleCommand(info, parsed, skeletons);
    }
    self.steam_client.packets.incoming.clearRetainingCapacity();
    self.steam_client.packet_mutex.unlock(self.io);
}

fn handleCommand(
    self: *@This(),
    info: *const Info,
    command: shared.net.ServerPacket,
    skeletons: *std.AutoHashMap(u32, SkeletonAnimation),
) !void {
    switch (command) {
        .acknowledge => |acknowledge| {
            info.world.camera = .{ .transform = .{ .position = .{ 0, 0, 0 } } };
            self.spawner.spawn(.{ .kind = .player, .server_id = acknowledge.id });
            self.my_server_id = acknowledge.id;
            std.log.debug("ack entities: {d}", .{info.world.next_id});
        },
        .spawn_entity => |spawn_entity| {
            if (info.world.enitity_mapping.contains(spawn_entity.id)) return;
            const server_id = spawn_entity.id;

            if (spawn_entity.kind == .unknown) @panic("unknown entity type... wtf");
            self.spawner.spawn(.{ .kind = spawn_entity.kind, .server_id = server_id, .data = spawn_entity.data });
            // std.log.debug("spawn entities : {d}", .{info.world.next_id});
            // std.log.debug("SPAWNED: MY ID: {d}, server ID: {d} ", .{ new_entity.id, spawn_entity.id });
        },
        .despawn_entity => |despawn_entity| {
            const server_id = despawn_entity.id;
            const my_id = info.world.enitity_mapping.get(server_id) orelse {
                std.log.debug("FAILED TO GET- SERVER ID: {d},  ", .{server_id});
                return;
            };
            try self.spawner.depspawn(my_id);
            // std.log.debug("DESPAWNED: MY ID: {d}, server ID: {d} ", .{ my_id, server_id });
        },
        .update_transform => |update_transform_command| {
            const id = info.world.enitity_mapping.get(update_transform_command.id) orelse return;
            const entity = info.world.getPtr(id) orelse {
                std.log.debug("FAILED TO GET- SERVER ID: {d},  ", .{update_transform_command.id});
                return;
            };

            // std.log.debug(" - SERVER ID: {d} == 94, MY_ID {d} == 93 ", .{ update_transform_command.id, id });
            entity.transform.position = @floatCast(update_transform_command.position);
            entity.transform.rotation = .fromVec(@floatCast(update_transform_command.rotation));
        },
        .update_camera_rotation => |rotation_command| {
            // const id = info.world.enitity_mapping.get(rotation_command.id) orelse return;
            // const entity = info.world.getPtr(id) orelse return;
            info.world.camera.transform.rotation = .fromVec(rotation_command.rotation);
            info.world.camera.transform.position = rotation_command.position;
        },
        .add_health => |health_command| {
            if (self.my_server_id == health_command.id) {
                info.world.camera.health += health_command.amount;
            }
        },
        .update_state => |state_command| {
            const entity = info.world.getServerEntityPtr(state_command.id) orelse return;
            entity.state = state_command.state;
            const skeleton_animation = skeletons.getPtr(entity.id) orelse return;
            skeleton_animation.active, skeleton_animation.loop = switch (entity.kind) {
                .player => switch (entity.state) {
                    .idle => .{ 0, true },
                    .walk => .{ 1, true },
                    .attack => .{ 2, false },
                },
                else => if (shared.Entity.isEnemy(entity.kind))
                    switch (entity.state) {
                        .idle => .{ 0, true },
                        .walk => .{ 1, true },
                        .attack => .{ 2, false },
                    }
                else
                    .{ skeleton_animation.default, true },
            };

            if (skeleton_animation.loop == false) {
                skeleton_animation.curremt_time = 0;
            }
        },
    }
}
