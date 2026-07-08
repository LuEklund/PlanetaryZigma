const std = @import("std");
const shared = @import("shared");
const tracy = @import("ztracy");
const Client = shared.SteamNet.Client;
const system = @import("../system.zig");
const World = system.World;
const Spawner = @import("Spawner.zig");
const Info = system.Info;
const nz = shared.numz;
const SkeletonInstance = @import("../Renderer/Vulkan/SkeletonInstance.zig");
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
/// Whether we've sent the "connect" handshake on the current server_conn.
server_tick_estimate: f32 = 0,
server_tick_latest: u32 = 0,
render_delay_ticks: f32 = 1,
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
    skeletons: *std.AutoHashMap(u32, SkeletonInstance),
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
        var input = info.world.controller.input_map;
        if (info.world.controller.free_camera) input.keys = .{};
        try self.sendCommand(.{ .input = input }, .unreliable_no_delay);
        // std.log.debug("input_map: {any}", .{entity.camera.input_map});
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

    self.server_tick_estimate += info.delta_time / shared.tick_seconds;
    const target = @as(f32, @floatFromInt(self.server_tick_latest)) - self.render_delay_ticks;
    self.server_tick_estimate += (target - self.server_tick_estimate) * 0.1;

    self.steam_client.packet_mutex.unlock(self.io);
}

fn handleCommand(
    self: *@This(),
    info: *const Info,
    command: shared.net.ServerPacket,
    skeletons: *std.AutoHashMap(u32, SkeletonInstance),
) !void {
    switch (command) {
        .acknowledge => |acknowledge| {
            info.world.camera = .{ .transform = .{ .position = .{ 0, 0, 0 } } };
            self.spawner.spawn(.{ .kind = .player, .id = acknowledge.id, .data = .none });
            info.world.player_id = acknowledge.id;
            self.server_tick_estimate = @as(f32, @floatFromInt(acknowledge.tick)) - self.render_delay_ticks;
            self.server_tick_latest = acknowledge.tick;
        },
        .spawn_entity => |spawn_entity| {
            if (info.world.getPtr(spawn_entity.id) != null) return;
            if (spawn_entity.kind == .unknown) @panic("unknown entity type... wtf");

            self.spawner.spawn(spawn_entity);
        },
        .despawn_entity => |despawn_entity| {
            // Spawner resolves it after spawns are applied, so a spawn+despawn
            // arriving in the same batch can't drop the despawn.
            try self.spawner.depspawn(despawn_entity.id);
        },
        .update_motion => |update_motion_command| {
            const entity = info.world.getPtr(update_motion_command.id) orelse return;
            entity.update_motion = update_motion_command;
        },
        .server_tick => |tick| {
            self.server_tick_latest = @max(self.server_tick_latest, tick);
        },
        .update_stat => |update_stat_command| {
            const entity = info.world.getPtr(update_stat_command.id) orelse {
                self.spawner.pending_stats.appendAssumeCapacity(update_stat_command);
                return;
            };
            Spawner.applyStat(entity, update_stat_command);
        },
        .update_event => |event| {
            switch (event) {
                .teleport_start => if (info.world.getPtr(info.world.teleporter_id)) |entity| {
                    entity.teleporter.active = true;
                },
                .teleporter_charge => |charged| if (info.world.getPtr(info.world.teleporter_id)) |entity| {
                    entity.teleporter.charged = charged;
                },
                .new_stage => info.world.teleporter_id = 0,
                .attack => |id| {
                    const skeleton_animation = skeletons.getPtr(id) orelse return;
                    const state_clip = skeleton_animation.model.state_clips.get(.attack);
                    skeleton_animation.player.active = state_clip.index;
                    skeleton_animation.player.loop = state_clip.loop;
                    skeleton_animation.player.current_time = skeleton_animation.model.clips[state_clip.index].start;
                },
            }
        },
        .update_inventory => |inventory| {
            const entity = info.world.getPtr(inventory.id) orelse return;
            entity.inventory.set(inventory.item_kind, inventory.set);
        },
    }
}
