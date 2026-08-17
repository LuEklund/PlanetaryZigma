const NetworkManager = @This();

const std = @import("std");
const builtin = @import("builtin");
const shared = @import("shared");
const tracy = @import("ztracy");
const Client = shared.SteamNet.Client;

gpa: std.mem.Allocator,
io: std.Io,
steam_client: Client,
server_conn: shared.SteamNet.Connection = 0,
server_tick_estimate: f32 = 0,
server_tick_latest: u32 = 0,
render_delay_ticks: f32 = 1,
sent_connect: bool = false,
ping_milliseconds: i32 = -1,
server_list: ServerList = .{},
host_state: HostState = .none,
host_intent: HostIntent = .none,
host_state_time: f32 = 0,
elapsed_time: f32 = 0,
steam_logged_on: bool = false,
server_process: ?std.process.Child = null,
dev_mode: bool = false,
packets: std.ArrayList(shared.net.ServerPacket) = .empty,
chat_text: std.ArrayList(u8) = .empty,

pub const host_wait_timeout_seconds: f32 = 15;
pub const max_chat_text_bytes: usize = shared.max_chat_len * 32;

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

pub const Phase = enum(u8) {
    idle,
    starting_server,
    waiting_for_server,
    connecting,
    connected,

    pub fn text(self: Phase) []const u8 {
        return switch (self) {
            .idle => "",
            .starting_server => "Starting server...",
            .waiting_for_server => "Waiting for server...",
            .connecting => "Connecting...",
            .connected => "Entering ship...",
        };
    }
};

pub fn phase(self: *const NetworkManager) Phase {
    if (self.server_conn != 0) return .connected;
    if (self.steam_client.server_conn != 0) return .connecting;
    return switch (self.host_state) {
        .requested => .starting_server,
        .waiting => .waiting_for_server,
        .hosting => .connecting,
        .none, .failed, .steam_offline => .idle,
    };
}

fn setHostState(self: *NetworkManager, next: HostState) void {
    if (self.host_state == next) return;
    std.log.info("host: {t} -> {t} after {d:.2}s (intent={t})", .{
        self.host_state,
        next,
        self.elapsed_time - self.host_state_time,
        self.host_intent,
    });
    self.host_state = next;
    self.host_state_time = self.elapsed_time;
}

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
    log_connection_status: bool,
) !void {
    self.* = .{
        .gpa = gpa,
        .io = io,
        .steam_client = undefined,
        .packets = try .initCapacity(gpa, shared.max_entities * 2),
        .chat_text = try .initCapacity(gpa, max_chat_text_bytes),
    };
    try self.steam_client.init(gpa, io, log_connection_status);
    self.steam_logged_on = self.steam_client.isLoggedOn();
}

pub fn deinit(self: *NetworkManager) void {
    if (self.server_process) |*child| child.kill(self.io);
    self.packets.deinit(self.gpa);
    self.chat_text.deinit(self.gpa);
    self.steam_client.deinit();
}

fn stopHostServer(self: *NetworkManager) void {
    if (self.server_process) |*child| child.kill(self.io);
    self.server_process = null;
}

pub fn connected(self: *const NetworkManager) bool {
    return self.server_conn != 0;
}

pub fn returnToMainMenu(self: *NetworkManager) !void {
    try self.steam_client.packet_mutex.lock(self.io);
    defer self.steam_client.packet_mutex.unlock(self.io);
    self.steam_client.disconnect();

    self.stopHostServer();
    self.packets.clearRetainingCapacity();
    self.chat_text.clearRetainingCapacity();
    self.server_conn = 0;
    self.server_tick_estimate = 0;
    self.server_tick_latest = 0;
    self.sent_connect = false;
    self.setHostState(.none);
    self.host_intent = .none;
}

pub fn requestHost(self: *NetworkManager, intent: HostIntent, dev_mode: bool) void {
    self.dev_mode = dev_mode;
    if (intent == .multiplayer and !self.steam_logged_on) {
        self.host_intent = intent;
        self.setHostState(.steam_offline);
        return;
    }
    if (self.host_state == .none or self.host_state == .failed or self.host_state == .steam_offline) {
        self.host_intent = intent;
        self.setHostState(.requested);
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
        std.log.err("host: {s} not found; build the server for this OS first", .{server_exe_name});
        self.setHostState(.failed);
        return;
    };

    var server_id_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const server_id_path = std.fmt.bufPrint(&server_id_path_buf, "{s}/{s}", .{ host_server.dir, shared.SteamNet.Server.server_file_name }) catch unreachable;
    std.Io.Dir.deleteFileAbsolute(self.io, server_id_path) catch {};

    var host_steam_id_buf: [20]u8 = undefined;
    const host_steam_id_text = std.fmt.bufPrint(&host_steam_id_buf, "{d}", .{self.steam_client.user_steam_id}) catch unreachable;
    const argv: []const []const u8 = if (self.host_intent == .singleplayer)
        if (self.dev_mode) &.{ host_server.exe_path, "--dev", "--local-singleplayer" } else &.{ host_server.exe_path, "--local-singleplayer" }
    else if (self.dev_mode)
        &.{ host_server.exe_path, "--dev", host_steam_id_text }
    else
        &.{ host_server.exe_path, host_steam_id_text };
    std.log.info("host: spawning {s} (cwd={s}, id_file={s})", .{ host_server.exe_path, host_server.dir, server_id_path });
    for (argv, 0..) |arg, index| std.log.info("host: argv[{d}]=\"{s}\"", .{ index, arg });
    self.server_process = std.process.spawn(self.io, .{
        .argv = argv,
        .cwd = .{ .path = host_server.dir },
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
        .create_no_window = true,
    }) catch |err| {
        std.log.err("host: spawn failed: {t}", .{err});
        self.setHostState(.failed);
        return;
    };
    self.setHostState(.waiting);
}

fn sendConnect(self: *NetworkManager) !void {
    const name = self.playerDisplayName();
    const cmd: shared.net.ClientPacket = .{ .connect = .{ .protocol_version = shared.net.protocol_version, .player_name = .copy(name) } };
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
    try self.steam_client.packets.pushOutgoing(self.gpa, self.server_conn, w.buffered(), flags);
}

pub fn update(self: *NetworkManager, player_input: shared.net.Input, elapsed_time: f32, delta_time: f32) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    self.packets.clearRetainingCapacity();
    self.chat_text.clearRetainingCapacity();
    try self.steam_client.packet_mutex.lock(self.io);
    defer self.steam_client.packet_mutex.unlock(self.io);

    self.elapsed_time = elapsed_time;
    self.steam_logged_on = self.steam_client.isLoggedOn();
    self.ping_milliseconds = self.steam_client.pingMilliseconds();
    if (!self.steam_logged_on) {
        self.server_list.refresh = false;
        self.server_list.count = 0;
        if (self.host_intent == .multiplayer and (self.host_state == .requested or self.host_state == .waiting or self.host_state == .hosting)) {
            std.log.warn("host: steam went offline mid-host, killing server", .{});
            self.stopHostServer();
            self.setHostState(.steam_offline);
        }
    } else if (self.host_state == .steam_offline) {
        self.host_intent = .none;
        self.setHostState(.none);
    }

    if (self.host_state == .requested) self.spawnHostServer();
    if (self.host_state == .waiting) {
        for (server_dir_candidates) |dir| {
            var id_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const id_path = std.fmt.bufPrint(&id_path_buf, "{s}/{s}", .{ dir, shared.SteamNet.Server.server_file_name }) catch unreachable;
            var id_buf: [20]u8 = undefined;
            if (std.Io.Dir.cwd().readFile(self.io, id_path, &id_buf)) |id_text| {
                std.log.info("host: read {s} = \"{s}\"", .{ id_path, id_text });
                self.setHostState(.hosting);
                std.Io.Dir.cwd().deleteFile(self.io, id_path) catch {};
                if (std.mem.startsWith(u8, id_text, "local:")) {
                    const port = std.fmt.parseInt(u16, id_text["local:".len..], 10) catch 0;
                    if (port == 0) {
                        std.log.err("host: bad local server file \"{s}\"", .{id_text});
                    } else if (self.steam_client.server_conn == 0) {
                        try self.steam_client.connectToLocalServer(port);
                    }
                } else if (self.steam_client.server_conn == 0) {
                    const server_steam_id = std.fmt.parseInt(u64, id_text, 10) catch 0;
                    if (server_steam_id == 0) {
                        std.log.err("host: bad server id file \"{s}\"", .{id_text});
                    } else {
                        try self.steam_client.connectToServer(server_steam_id);
                    }
                }
            } else |_| {}
        }
        if (self.host_state == .waiting and self.elapsed_time - self.host_state_time > host_wait_timeout_seconds) {
            std.log.err("host: server never wrote {s} within {d:.0}s; giving up", .{
                shared.SteamNet.Server.server_file_name,
                host_wait_timeout_seconds,
            });
            self.stopHostServer();
            self.setHostState(.failed);
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
            std.log.info("host: connected (conn={d}) {d:.2}s after {t}", .{ conn, self.elapsed_time - self.host_state_time, self.host_state });
            self.server_conn = conn;
            self.sent_connect = false;
        },
        .disconnected => |conn| {
            const reached_game = self.server_conn == conn;
            std.log.warn("host: disconnected (conn={d}) while phase={t}, reached_game={}", .{ conn, self.phase(), reached_game });
            if (reached_game) {
                self.server_conn = 0;
                self.sent_connect = false;
            }
            if (self.host_state == .waiting or self.host_state == .hosting) {
                self.stopHostServer();
                self.setHostState(if (reached_game) .none else .failed);
            }
        },
    };
    self.steam_client.packets.events.clearRetainingCapacity();

    if (self.server_conn != 0 and !self.sent_connect) {
        try self.sendConnect();
        self.sent_connect = true;
    }
    if (self.server_conn != 0) {
        try self.sendCommand(.{ .input = player_input }, .unreliable_no_delay);
    }

    for (self.steam_client.packets.incoming.items) |*msg| {
        if (self.packets.items.len == self.packets.capacity) {
            std.log.warn("packet inbox full at {d}, dropping the rest of this frame", .{self.packets.capacity});
            break;
        }
        var msg_reader: std.Io.Reader = .fixed(msg.slice());
        const reader = &msg_reader;
        var parsed = shared.net.parse(shared.net.ServerPacket, reader) catch |err| {
            std.log.err("parse packet: {s}", .{@errorName(err)});
            continue;
        };
        switch (parsed) {
            .acknowledge => |acknowledge| {
                self.server_tick_estimate = @as(f32, @floatFromInt(acknowledge.tick)) - self.render_delay_ticks;
                self.server_tick_latest = acknowledge.tick;
            },
            .server_tick => |tick| {
                self.server_tick_latest = @max(self.server_tick_latest, tick);
            },
            .chat_message => |chat_message| {
                var owned_chat_message: shared.net.ChatMessage = chat_message;
                owned_chat_message.text = self.keepChatText(chat_message.text) orelse continue;
                parsed = .{ .chat_message = owned_chat_message };
            },
            else => {},
        }
        self.packets.appendAssumeCapacity(parsed);
    }
    self.steam_client.packets.incoming.clearRetainingCapacity();

    self.server_tick_estimate += delta_time / shared.tick_seconds;
    const target = @as(f32, @floatFromInt(self.server_tick_latest)) - self.render_delay_ticks;
    self.server_tick_estimate += (target - self.server_tick_estimate) * 0.1;
}

fn keepChatText(self: *NetworkManager, text: []const u8) ?[]const u8 {
    if (self.chat_text.items.len + text.len > self.chat_text.capacity) {
        std.log.warn("chat text scratch full, dropping message of {d} bytes", .{text.len});
        return null;
    }
    const start = self.chat_text.items.len;
    self.chat_text.appendSliceAssumeCapacity(text);
    return self.chat_text.items[start..][0..text.len];
}
