const NetworkManager = @This();

const std = @import("std");
const builtin = @import("builtin");
const shared = @import("shared");
const tracy = @import("ztracy");
const Client = shared.SteamNet.Client;
const system = @import("../system.zig");
const Particle = @import("Particle.zig");
const World = system.World;
const Info = system.Info;
const nz = shared.numz;

gpa: std.mem.Allocator,
io: std.Io,
steam_client: *Client,
server_conn: shared.SteamNet.Connection = 0,
server_tick_estimate: f32 = 0,
server_tick_latest: u32 = 0,
render_delay_ticks: f32 = 1,
sent_connect: bool = false,
ping_milliseconds: i32 = -1,
server_list: ServerList = .{},
host_state: HostState = .none,
host_intent: HostIntent = .none,
steam_logged_on: bool = false,
server_process: ?std.process.Child = null,

pub const HostState = enum(u8) {
    none,
    requested,
    waiting,
    hosting,
    failed,
    steam_offline,
};

pub const HostIntent = enum(u8) {
    none,
    singleplayer,
    multiplayer,
};

const ServerList = struct {
    servers: [8]Client.ServerInfo = undefined,
    count: usize = 0,
    refresh: bool = true,
};

const server_exe_name = if (builtin.os.tag == .windows) "server.exe" else "server";
const server_dir_candidates = [_][]const u8{ "../server", "server", "../../../server" };
const server_exe_rel_candidates = [_][]const u8{ server_exe_name, "zig-out/bin/" ++ server_exe_name };

const HostServer = struct {
    dir: []const u8,
    exe_path: []const u8,
};

pub fn init(
    self: *NetworkManager,
    gpa: std.mem.Allocator,
    io: std.Io,
    net: *shared.SteamNet.Client,
) !void {
    self.* = .{
        .gpa = gpa,
        .io = io,
        .steam_client = net,
        .steam_logged_on = net.isLoggedOn(),
    };
}

pub fn deinit(self: *NetworkManager) void {
    if (self.server_process) |*child| child.kill(self.io);
}

fn stopHostServer(self: *NetworkManager) void {
    if (self.server_process) |*child| child.kill(self.io);
    self.server_process = null;
}

pub fn connected(self: *const NetworkManager) bool {
    return self.server_conn != 0 or self.steam_client.server_conn != 0;
}

pub fn returnToMainMenu(self: *NetworkManager) !void {
    try self.steam_client.packet_mutex.lock(self.io);
    defer self.steam_client.packet_mutex.unlock(self.io);
    self.steam_client.disconnect();

    self.stopHostServer();
    self.server_conn = 0;
    self.server_tick_estimate = 0;
    self.server_tick_latest = 0;
    self.sent_connect = false;
    self.host_state = .none;
    self.host_intent = .none;
}

pub fn requestHost(self: *NetworkManager, intent: HostIntent) void {
    if (intent == .multiplayer and !self.steam_logged_on) {
        self.host_state = .steam_offline;
        self.host_intent = intent;
        return;
    }
    if (self.host_state == .none or self.host_state == .failed or self.host_state == .steam_offline) {
        self.host_state = .requested;
        self.host_intent = intent;
    }
}

fn findHostServer(self: *NetworkManager, dir_buf: *[std.Io.Dir.max_path_bytes]u8, exe_path_buf: *[std.Io.Dir.max_path_bytes]u8) ?HostServer {
    for (server_dir_candidates) |candidate| {
        var server_dir = std.Io.Dir.cwd().openDir(self.io, candidate, .{}) catch continue;
        defer server_dir.close(self.io);

        for (server_exe_rel_candidates) |exe_rel| {
            server_dir.access(self.io, exe_rel, .{}) catch continue;

            const dir_len = server_dir.realPath(self.io, dir_buf) catch continue;
            const exe_path_len = server_dir.realPathFile(self.io, exe_rel, exe_path_buf) catch continue;
            return .{
                .dir = dir_buf[0..dir_len],
                .exe_path = exe_path_buf[0..exe_path_len],
            };
        }
    }
    return null;
}

fn spawnHostServer(self: *NetworkManager) void {
    var server_dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var server_exe_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const host_server = self.findHostServer(&server_dir_buf, &server_exe_path_buf) orelse {
        self.host_state = .failed;
        std.log.err("host: {s} not found; build the server for this OS first", .{server_exe_name});
        return;
    };

    var server_id_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const server_id_path = std.fmt.bufPrint(&server_id_path_buf, "{s}/{s}", .{ host_server.dir, shared.SteamNet.Server.server_file_name }) catch unreachable;
    std.Io.Dir.deleteFileAbsolute(self.io, server_id_path) catch {};

    var host_steam_id_buf: [20]u8 = undefined;
    const host_steam_id_text = std.fmt.bufPrint(&host_steam_id_buf, "{d}", .{self.steam_client.user_steam_id}) catch unreachable;
    const argv: []const []const u8 = if (self.host_intent == .singleplayer)
        &.{ host_server.exe_path, "--local-singleplayer" }
    else
        &.{ host_server.exe_path, host_steam_id_text };
    self.server_process = std.process.spawn(self.io, .{
        .argv = argv,
        .cwd = .{ .path = host_server.dir },
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
        .create_no_window = true,
    }) catch |err| {
        self.host_state = .failed;
        std.log.err("spawn host server: {t}", .{err});
        return;
    };
    self.host_state = .waiting;
}

fn sendConnect(self: *NetworkManager) !void {
    const name = self.playerDisplayName();
    const cmd: shared.net.ClientPacket = .{ .connect = .{ .protocol_version = shared.net.protocol_version, .name_len = @intCast(name.len), .name = name } };
    try self.sendCommand(cmd, .reliable);
}

fn playerDisplayName(self: *const NetworkManager) []const u8 {
    const steam_name = std.mem.trim(u8, self.steam_client.personaName(), " \t\r\n");
    return if (steam_name.len == 0)
        shared.default_player_name
    else
        steam_name[0..@min(steam_name.len, shared.max_player_name_len)];
}

pub fn sendCommand(self: *NetworkManager, command: shared.net.ClientPacket, flags: shared.SteamNet.SendFlags) !void {
    if (self.server_conn == 0) return;
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try shared.net.write(shared.net.ClientPacket, command, &w);
    // std.log.debug("len: {d}", .{w.buffered().len});
    try self.steam_client.packets.pushOutgoing(self.gpa, self.server_conn, w.buffered(), flags);
}

pub fn update(self: *NetworkManager, info: *const Info) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    try self.steam_client.packet_mutex.lock(self.io);
    defer self.steam_client.packet_mutex.unlock(self.io);

    self.steam_logged_on = self.steam_client.isLoggedOn();
    self.ping_milliseconds = self.steam_client.pingMilliseconds();
    if (!self.steam_logged_on) {
        self.server_list.refresh = false;
        self.server_list.count = 0;
        if (self.host_intent == .multiplayer and (self.host_state == .requested or self.host_state == .waiting or self.host_state == .hosting)) {
            self.stopHostServer();
            self.host_state = .steam_offline;
        }
    } else if (self.host_state == .steam_offline) {
        self.host_state = .none;
        self.host_intent = .none;
    }

    if (self.host_state == .requested) self.spawnHostServer();
    if (self.host_state == .waiting) {
        for (server_dir_candidates) |dir| {
            var id_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const id_path = std.fmt.bufPrint(&id_path_buf, "{s}/{s}", .{ dir, shared.SteamNet.Server.server_file_name }) catch unreachable;
            var id_buf: [20]u8 = undefined;
            if (std.Io.Dir.cwd().readFile(self.io, id_path, &id_buf)) |id_text| {
                self.host_state = .hosting;
                std.Io.Dir.cwd().deleteFile(self.io, id_path) catch {};
                if (std.mem.startsWith(u8, id_text, "local:")) {
                    const port = std.fmt.parseInt(u16, id_text["local:".len..], 10) catch 0;
                    if (port == 0) {
                        std.log.err("host: bad local server file", .{});
                    } else if (self.steam_client.server_conn == 0) {
                        try self.steam_client.connectToLocalServer(port);
                    }
                } else if (self.steam_client.server_conn == 0) {
                    const server_steam_id = std.fmt.parseInt(u64, id_text, 10) catch 0;
                    if (server_steam_id == 0) {
                        std.log.err("host: bad server id file", .{});
                    } else {
                        try self.steam_client.connectToServer(server_steam_id);
                    }
                }
            } else |_| {}
        }
    }

    if (self.steam_logged_on and self.server_list.refresh == true and self.steam_client.browser.list.refresh_state == .idle) {
        self.steam_client.browser.list.refresh_state = .request;
    } else if (self.steam_client.browser.list.refresh_state == .done) {
        self.server_list.refresh = false;
        self.steam_client.browser.list.refresh_state = .idle;
        for (0..self.steam_client.browser.list.count) |i| {
            self.server_list.servers[i] = self.steam_client.browser.list.servers[i];
            @memset(&self.server_list.servers[i].id_str, 0);
            _ = try std.fmt.bufPrint(&self.server_list.servers[i].id_str, "{d}", .{self.server_list.servers[i].steam_id});
            std.log.info("browser server[{d}] my_ver={d} tags=\"{s}\"", .{ i, shared.net.protocol_version, std.mem.sliceTo(self.server_list.servers[i].game_tags[0..], 0) });
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
    self: *NetworkManager,
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
                try info.world.applySpawnData(entity, spawn_entity);
                return;
            }
            if (spawn_entity.kind == .unknown) {
                std.log.err("spawn with unknown entity kind, ignoring", .{});
                return;
            }
            try self.queueSpawn(info.world, spawn_entity);
        },
        .despawn_entity => |despawn_entity| {
            info.world.pending_despawn.appendAssumeCapacity(despawn_entity.id);
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
                info.world.pending_stats.appendAssumeCapacity(update_stat_command);
                return;
            };
            World.applyStat(entity, update_stat_command);
        },
        .update_event => |event| {
            switch (event) {
                .teleport_start => if (info.world.getPtr(info.world.teleporter_id)) |entity| {
                    entity.teleporter.state = .active;
                },
                .teleporter_charge => |charged| if (info.world.getPtr(info.world.teleporter_id)) |entity| {
                    entity.teleporter.charged = charged;
                },
                .new_stage => |new_stage| {
                    info.world.teleporter_id = .none;
                    info.world.stage = new_stage;
                },
                .attack => |id| {
                    info.world.attack_events.appendAssumeCapacity(id);
                },
                .rocket_impact => |position| {
                    Particle.spawnRocketExplosion(&info.world.particles, info.world.prng.random(), position);
                },
                .interact => |interact| if (info.world.getPtr(interact.interactor)) |entity| {
                    std.log.debug("interacting", .{});
                    entity.interacting = interact.interacted;
                },
            }
        },
        .update_inventory => |inventory| {
            const entity = info.world.getPtr(inventory.id) orelse {
                info.world.pending_inventory.appendAssumeCapacity(inventory);
                return;
            };
            entity.inventory.set(inventory.item_kind, inventory.set);
        },
        .update_player_name => |player_name| {
            const entity = info.world.getPtr(player_name.id) orelse {
                try self.queuePlayerName(info.world, player_name);
                return;
            };
            if (entity.kind == .player) try info.world.setPlayerName(entity, player_name.name);
        },
        .set_currency => |set_currency| {
            if (info.world.getPtr(set_currency.id)) |entity| {
                entity.currency = set_currency.amount;
            }
        },
    }
}

fn queueSpawn(self: *NetworkManager, world: *World, spawn_entity: shared.net.SpawnEntity) !void {
    if (world.pending_spawn.items.len >= world.pending_spawn.capacity) return error.PendingSpawnFull;

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
    world.pending_spawn.appendAssumeCapacity(queued_spawn);
}

fn queuePlayerName(self: *NetworkManager, world: *World, player_name: shared.net.PlayerNameUpdate) !void {
    if (world.pending_player_names.items.len >= world.pending_player_names.capacity) return error.PendingPlayerNameFull;

    const name = try self.gpa.dupe(u8, player_name.name);
    world.pending_player_names.appendAssumeCapacity(.{
        .id = player_name.id,
        .name_len = @intCast(name.len),
        .name = name,
    });
}
