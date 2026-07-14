const std = @import("std");
const builtin = @import("builtin");
const shared = @import("shared");
const tracy = @import("ztracy");
const Client = shared.SteamNet.Client;
const system = @import("../system.zig");
const World = system.World;
const Spawner = @import("Spawner.zig");
const Info = system.Info;
const nz = shared.numz;

gpa: std.mem.Allocator,
io: std.Io,
steam_client: *Client,
server_conn: shared.SteamNet.Conn = 0,
server_tick_estimate: f32 = 0,
server_tick_latest: u32 = 0,
render_delay_ticks: f32 = 1,
sent_connect: bool = false,
server_list: ServerList = .{},
host_state: HostState = .none,
server_process: ?std.process.Child = null,

pub const HostState = enum(u8) {
    none,
    requested,
    waiting,
    hosting,
};

const ServerList = struct {
    servers: [8]Client.ServerInfo = undefined,
    count: usize = 0,
    refresh: bool = true,
};

pub fn init(
    self: *@This(),
    gpa: std.mem.Allocator,
    io: std.Io,
    net: *shared.SteamNet.Client,
) !void {
    self.* = .{
        .gpa = gpa,
        .io = io,
        .steam_client = net,
    };
}

pub fn deinit(self: *@This()) void {
    if (self.server_process) |*child| child.kill(self.io);
}

fn spawnHostServer(self: *@This()) void {
    self.host_state = .none;
    inline for (.{ "../server", "server" }) |dir| {
        if (std.Io.Dir.cwd().access(self.io, dir, .{})) |_| {
            std.Io.Dir.cwd().deleteFile(self.io, dir ++ "/" ++ shared.SteamNet.Server.server_file_name) catch {};
            var host_steam_id_buf: [20]u8 = undefined;
            const host_steam_id_text = std.fmt.bufPrint(&host_steam_id_buf, "{d}", .{self.steam_client.user_steam_id}) catch unreachable;
            const server_exe = if (builtin.os.tag == .windows) "zig-out/bin/server.exe" else "zig-out/bin/server";
            self.server_process = std.process.spawn(self.io, .{
                .argv = &.{ server_exe, host_steam_id_text },
                .cwd = .{ .path = dir },
            }) catch |err| {
                std.log.err("spawn host server: {t}", .{err});
                return;
            };
            self.host_state = .waiting;
            return;
        } else |_| {}
    }
    std.log.err("host: server directory not found", .{});
}

fn sendConnect(self: *@This()) !void {
    const name = self.playerDisplayName();
    const cmd: shared.net.ClientPacket = .{ .connect = .{ .name_len = @intCast(name.len), .name = name } };
    try self.sendCommand(cmd, .reliable);
}

fn playerDisplayName(self: *const @This()) []const u8 {
    const steam_name = std.mem.trim(u8, self.steam_client.personaName(), " \t\r\n");
    return if (steam_name.len == 0)
        shared.default_player_name
    else
        steam_name[0..@min(steam_name.len, shared.max_player_name_len)];
}

pub fn sendCommand(self: *@This(), command: shared.net.ClientPacket, flags: shared.SteamNet.SendFlags) !void {
    if (self.server_conn == 0) return;
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try shared.net.write(shared.net.ClientPacket, command, &w);
    // std.log.debug("len: {d}", .{w.buffered().len});
    try self.steam_client.packets.pushOutgoing(self.gpa, self.server_conn, w.buffered(), flags);
}

pub fn update(self: *@This(), info: *const Info) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    try self.steam_client.packet_mutex.lock(self.io);
    defer self.steam_client.packet_mutex.unlock(self.io);

    if (self.host_state == .requested) self.spawnHostServer();
    if (self.host_state == .waiting) {
        inline for (.{ "../server", "server" }) |dir| {
            const id_path = dir ++ "/" ++ shared.SteamNet.Server.server_file_name;
            var id_buf: [20]u8 = undefined;
            if (std.Io.Dir.cwd().readFile(self.io, id_path, &id_buf)) |id_text| {
                self.host_state = .hosting;
                std.Io.Dir.cwd().deleteFile(self.io, id_path) catch {};
                const server_steam_id = std.fmt.parseInt(u64, id_text, 10) catch 0;
                if (server_steam_id == 0) {
                    std.log.err("host: bad server id file", .{});
                } else if (self.steam_client.server_conn == 0) {
                    try self.steam_client.connectToServer(server_steam_id);
                }
            } else |_| {}
        }
    }

    if (self.server_list.refresh == true and self.steam_client.browser.list.refresh_state == .idle) {
        self.steam_client.browser.list.refresh_state = .request;
    } else if (self.steam_client.browser.list.refresh_state == .done) {
        self.server_list.refresh = false;
        self.steam_client.browser.list.refresh_state = .idle;
        for (0..self.steam_client.browser.list.count) |i| {
            self.server_list.servers[i] = self.steam_client.browser.list.servers[i];
            @memset(&self.server_list.servers[i].id_str, 0);
            _ = try std.fmt.bufPrint(&self.server_list.servers[i].id_str, "{d}", .{self.server_list.servers[i].steam_id});
        }
        self.server_list.count = self.steam_client.browser.list.count;
    }

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

    if (self.server_conn != 0 and !self.sent_connect) {
        try self.sendConnect();
        self.sent_connect = true;
    }
    if (self.server_conn != 0) {
        var input = info.world.controller.input_map;
        if (info.world.controller.free_camera) input.keys = .{};
        try self.sendCommand(.{ .input = input }, .unreliable_no_delay);
        // std.log.debug("input_map: {any}", .{entity.camera.input_map});
    }
    if (info.world.getPtr(info.world.player_id)) |player| {
        if (player.kind == .player and player.player_name.len == 0) {
            try info.world.setPlayerName(player, self.playerDisplayName());
        }
    }
    // std.log.debug("cmd size {d}", .{self.steam_client.packets.incoming.items.len});
    for (self.steam_client.packets.incoming.items) |*msg| {
        var msg_reader: std.Io.Reader = .fixed(msg.slice());
        const reader = &msg_reader;
        const parsed = shared.net.parse(shared.net.ServerPacket, reader) catch |err| {
            std.log.err("parse packet: {s}", .{@errorName(err)});
            continue;
        };
        try self.handleCommand(info, parsed);
    }
    self.steam_client.packets.incoming.clearRetainingCapacity();

    self.server_tick_estimate += info.delta_time / shared.tick_seconds;
    const target = @as(f32, @floatFromInt(self.server_tick_latest)) - self.render_delay_ticks;
    self.server_tick_estimate += (target - self.server_tick_estimate) * 0.1;
}

fn handleCommand(
    self: *@This(),
    info: *const Info,
    command: shared.net.ServerPacket,
) !void {
    switch (command) {
        .acknowledge => |acknowledge| {
            const name = self.playerDisplayName();
            info.world.camera = .{ .transform = .{ .position = .{ 0, 0, 0 } } };
            try self.queueSpawn(info.world, .{ .kind = .player, .id = acknowledge.id, .data = .{ .player_name = .{ .name_len = @intCast(name.len), .name = name } } });
            info.world.player_id = acknowledge.id;
            self.server_tick_estimate = @as(f32, @floatFromInt(acknowledge.tick)) - self.render_delay_ticks;
            self.server_tick_latest = acknowledge.tick;
        },
        .spawn_entity => |spawn_entity| {
            if (info.world.getPtr(spawn_entity.id)) |entity| {
                try Spawner.applySpawnData(info.world, entity, spawn_entity);
                return;
            }
            if (spawn_entity.kind == .unknown) {
                std.log.err("spawn with unknown entity kind, ignoring", .{});
                return;
            }

            try self.queueSpawn(info.world, spawn_entity);
        },
        .despawn_entity => |despawn_entity| {
            info.world.pending_despawn.append(despawn_entity.id);
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
                info.world.pending_stats.append(update_stat_command);
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
                .new_stage => |new_stage| {
                    info.world.teleporter_id = .none;
                    info.world.stage = new_stage;
                },
                .attack => |id| {
                    info.world.attack_events.append(id);
                },
            }
        },
        .update_inventory => |inventory| {
            const entity = info.world.getPtr(inventory.id) orelse return;
            entity.inventory.set(inventory.item_kind, inventory.set);
        },
    }
}

fn queueSpawn(self: *@This(), world: *World, spawn_entity: shared.net.SpawnEntity) !void {
    if (world.pending_spawn.items.len >= world.pending_spawn.buffer.len) return error.PendingSpawnFull;

    var queued_spawn = spawn_entity;
    switch (spawn_entity.data) {
        .player_name => |player_name| {
            const name = try self.gpa.dupe(u8, player_name.name);
            queued_spawn.data = .{ .player_name = .{
                .name_len = @intCast(name.len),
                .name = name,
            } };
        },
        .none, .planet_radius, .is_teleporter_boss => {},
    }
    world.pending_spawn.append(queued_spawn);
}
