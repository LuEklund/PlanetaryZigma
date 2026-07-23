const Server = @This();

const std = @import("std");
const steam = @import("steamworks");
const Packets = @import("../SteamNet.zig").Packets;
const SteamNet = @import("../SteamNet.zig");

connections: [max_connections]steam.HSteamNetConnection = @splat(0),

host_steam_id: u64,
host_conn: steam.HSteamNetConnection,
host_state: HostState,
mode: Mode,

handle_packets_future: std.Io.Future(@typeInfo(@TypeOf(handlePackets)).@"fn".return_type.?),
packet_mutex: std.Io.Mutex = .init,
last_send_result: steam.EResult = .k_EResultOK,

gpa: std.mem.Allocator,
io: std.Io,
pipe: steam.HSteamPipe,
gs: steam.ISteamGameServer,
socket: steam.ISteamNetworkingSockets,
listen_socket: steam.HSteamListenSocket,
packets: Packets,

pub const max_connections: usize = 32;
pub const server_file_name = "server_id";

pub const Mode = enum(u8) {
    steam_p2p,
    local_singleplayer,
};

pub const InitOptions = struct {
    mode: Mode = .steam_p2p,
    host_steam_id: u64 = 0,
};

pub const HostState = enum(u8) {
    none,
    waiting,
    connected,
    left,
};

pub fn init(gpa: std.mem.Allocator, io: std.Io, options: InitOptions) !Server {
    const server_mode: steam.EServerMode = switch (options.mode) {
        .steam_p2p => .eServerModeAuthentication,
        .local_singleplayer => .eServerModeNoAuthentication,
    };
    if (!steam.Server.SteamInternal_GameServer_Init(
        0,
        27016,
        27017,
        steam.STEAMGAMESERVER_QUERY_PORT_SHARED,
        server_mode,
        "1.0.0.0",
    )) @panic("failed to init steam game server");

    const gs = steam.SteamGameServer();
    gs.SetGameDescription("Planetary Zigma dedicated server");
    gs.SetModDir("planetaryzigma");
    gs.SetDedicatedServer(true);
    gs.SetMaxPlayerCount(16);
    gs.SetServerName("Planetary Zigma");
    gs.SetMapName("default");
    gs.SetPasswordProtected(false);
    var product_buf: [16]u8 = undefined;
    const product = std.fmt.bufPrintZ(&product_buf, "{d}", .{steam.SteamGameServerUtils().GetAppID()}) catch unreachable;
    gs.SetProduct(product);
    gs.SetAdvertiseServerActive(options.mode == .steam_p2p);

    steam.SteamAPI_ManualDispatch_Init();
    const pipe = steam.SteamGameServer_GetHSteamPipe();

    if (options.mode == .steam_p2p) {
        gs.LogOnAnonymous();

        var connected = false;
        var deadline: u32 = 0;
        while (!connected and deadline < 1000) : (deadline += 1) {
            switch (try steamCallback(null, gpa, pipe, null)) {
                101 => connected = true,
                else => {},
            }

            try io.sleep(.{ .nanoseconds = std.time.ns_per_s }, .real);
        }
        if (!connected) return error.LogonTimeout;
    }

    std.log.info("\nSTEAM_ID {d}\n", .{gs.GetSteamID()});

    const sock = steam.SteamGameServerNetworkingSockets_SteamAPI();
    const listen = switch (options.mode) {
        .steam_p2p => sock.CreateListenSocketP2P(0, &.{}),
        .local_singleplayer => listen: {
            var address: steam.SteamNetworkingIPAddr = undefined;
            address.Clear();
            address.SetIPv4(0x7f000001, SteamNet.local_server_port);
            const option = SteamNet.allowIpWithoutAuthOption();
            break :listen sock.CreateListenSocketIP(&address, &.{option});
        },
    };
    if (listen == 0) return error.ListenFailed;

    switch (options.mode) {
        .steam_p2p => if (options.host_steam_id != 0) {
            var id_buf: [20]u8 = undefined;
            const id_text = try std.fmt.bufPrint(&id_buf, "{d}", .{gs.GetSteamID()});
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = server_file_name, .data = id_text });
        },
        .local_singleplayer => {
            var id_buf: [20]u8 = undefined;
            const id_text = try std.fmt.bufPrint(&id_buf, "local:{d}", .{SteamNet.local_server_port});
            std.log.info("local singleplayer listening on localhost:{d}", .{SteamNet.local_server_port});
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = server_file_name, .data = id_text });
        },
    }

    return .{
        .gpa = gpa,
        .pipe = pipe,
        .gs = gs,
        .socket = sock,
        .listen_socket = listen,
        .io = io,
        .packets = .{},
        .handle_packets_future = undefined,
        .host_steam_id = options.host_steam_id,
        .host_conn = 0,
        .host_state = if (options.host_steam_id != 0 or options.mode == .local_singleplayer) .waiting else .none,
        .mode = options.mode,
    };
}

pub fn updateSessionMetadata(self: *Server, max_players: usize, protocol_version: u32, host_name: []const u8, player_names: []const []const u8) void {
    self.gs.SetMaxPlayerCount(@intCast(max_players));

    const host = if (host_name.len == 0) "Unknown" else host_name;

    var server_name_buf: [64]u8 = undefined;
    const server_name = std.fmt.bufPrintZ(&server_name_buf, "{s}'s Session", .{host}) catch
        std.fmt.bufPrintZ(&server_name_buf, "Planetary Zigma", .{}) catch unreachable;
    self.gs.SetServerName(server_name);

    var tags_buf: [128]u8 = @splat(0);
    writeSessionTags(&tags_buf, protocol_version, host, player_names) catch {};
    self.gs.SetGameTags(&tags_buf[0]);
}

pub fn deinit(self: *Server) void {
    if (self.listen_socket != 0) _ = self.socket.CloseListenSocket(self.listen_socket);
    steam.Server.SteamGameServer_Shutdown();
    self.packets.deinit(self.gpa);
}

fn writeSessionTags(buffer: *[128]u8, protocol_version: u32, host_name: []const u8, player_names: []const []const u8) !void {
    var writer: std.Io.Writer = .fixed(buffer[0 .. buffer.len - 1]);
    try writer.print("ver={d};", .{protocol_version});
    try writer.writeAll("host=");
    try writeTagValue(&writer, host_name);
    try writer.writeAll(";players=");
    if (player_names.len == 0) {
        try writer.writeAll("none");
        return;
    }
    for (player_names, 0..) |player_name, i| {
        if (i != 0) try writer.writeAll(", ");
        try writeTagValue(&writer, player_name);
    }
}

fn writeTagValue(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |char| {
        try writer.writeByte(switch (char) {
            0...31, 127, ';', ',' => ' ',
            else => char,
        });
    }
}

pub fn handlePackets(self: *Server) !void {
    defer std.log.warn("packet pump exited", .{});
    var last_iteration: std.Io.Timestamp = .now(self.io, .real);
    var last_status_log = last_iteration;
    while (true) {
        const now: std.Io.Timestamp = .now(self.io, .real);
        const gap_milliseconds = @divFloor(last_iteration.durationTo(now).nanoseconds, std.time.ns_per_ms);
        if (gap_milliseconds > 100) std.log.warn("packet pump stalled {d}ms", .{gap_milliseconds});
        last_iteration = now;
        if (@import("../SteamNet.zig").log_connection_status and last_status_log.durationTo(now).nanoseconds > std.time.ns_per_s) {
            last_status_log = now;
            for (self.connections) |conn| {
                if (conn != 0) @import("../SteamNet.zig").logConnectionStatus(self.socket, conn);
            }
        }
        try self.io.checkCancel();
        {
            try self.packet_mutex.lock(self.io);
            defer self.packet_mutex.unlock(self.io);
            _ = self.steamCallback(self.gpa, self.pipe, self.socket) catch |err|
                std.log.err("steamCallback: {s}", .{@errorName(err)});
            self.recievePackets() catch |err|
                std.log.err("recievePackets: {s}", .{@errorName(err)});
            self.sendPackets() catch |err|
                std.log.err("sendPackets: {s}", .{@errorName(err)});
        }
        try self.io.sleep(.{ .nanoseconds = 1_000_000 }, .real);
    }
}

pub fn recievePackets(self: *Server) !void {
    var msgs: [16][*c]steam.SteamNetworkingMessage_t = undefined;
    for (self.connections) |conn| {
        if (conn == 0) continue;
        var status: steam.SteamNetConnectionRealTimeStatus_t = undefined;
        _ = self.socket.GetConnectionRealTimeStatus(conn, &status, &.{});

        // std.debug.print("\rpending_unrel: {}, pending_rel: {}, ping: {}, quality: {d:.2}, out_Bps: {d:.0}\n", .{
        //     status.m_cbPendingUnreliable,
        //     status.m_cbPendingReliable,
        //     status.m_nPing,
        //     status.m_flConnectionQualityLocal,
        //     status.m_flOutBytesPerSec,
        // });
        while (true) {
            const n = self.socket.ReceiveMessagesOnConnection(conn, &msgs[0], @intCast(msgs.len));
            if (n <= 0) break;
            const cnt: usize = @intCast(n);
            for (msgs[0..cnt]) |raw| {
                if (raw == null) continue;
                const m: *steam.SteamNetworkingMessage_t = raw;
                defer m.Release();
                if (m.m_pData == null or m.m_cbSize <= 0) continue;
                const bytes = m.m_pData[0..@intCast(m.m_cbSize)];
                try self.packets.pushIncoming(self.gpa, conn, bytes);
            }
        }
    }
}

pub fn sendPackets(self: *Server) !void {
    if (self.packets.outgoing.items.len == 0) return;
    for (self.packets.outgoing.items) |*msg| {
        var msg_num: i64 = 0;
        const result = self.socket.SendMessageToConnection(msg.conn, msg.bytes[0..msg.len], @intFromEnum(msg.flags), &msg_num);
        if (result != self.last_send_result) {
            self.last_send_result = result;
            std.log.warn("send result changed: {t} (conn={d})", .{ result, msg.conn });
        }
    }
    self.packets.outgoing.clearRetainingCapacity();
}

fn steamCallback(
    self: ?*Server,
    gpa: std.mem.Allocator,
    pipe: steam.HSteamPipe,
    socket: ?steam.ISteamNetworkingSockets,
) !i32 {
    steam.SteamAPI_ManualDispatch_RunFrame(pipe);
    var msg: steam.CallbackMsg_t = undefined;
    while (steam.SteamAPI_ManualDispatch_GetNextCallback(pipe, &msg)) {
        defer steam.SteamAPI_ManualDispatch_FreeLastCallback(pipe);
        switch (msg.m_iCallback) {
            102 => return error.SteamServersConnectFailure,
            1221 => {
                const data = msg.data() orelse return msg.m_iCallback;
                const event = data.SteamNetConnectionStatusChangedCallback;
                std.log.info("server net state: {s} (conn={d})", .{ @tagName(event.m_info.m_eState), event.m_hConn });
                switch (event.m_info.m_eState) {
                    .k_ESteamNetworkingConnectionState_Connecting => {
                        if (socket) |sock| {
                            const result = sock.AcceptConnection(event.m_hConn);
                            std.log.info("AcceptConnection -> {s}", .{@tagName(result)});
                        }
                    },
                    .k_ESteamNetworkingConnectionState_Connected => {
                        var remote_identity = event.m_info.m_identityRemote;
                        if (self.?.host_steam_id != 0 and remote_identity.GetSteamID64() == self.?.host_steam_id and self.?.host_state != .connected) {
                            self.?.host_conn = event.m_hConn;
                            self.?.host_state = .connected;
                            std.log.info("host connected (conn={d})", .{event.m_hConn});
                        } else if (self.?.mode == .local_singleplayer and self.?.host_conn == 0) {
                            self.?.host_conn = event.m_hConn;
                            self.?.host_state = .connected;
                            std.log.info("local host connected (conn={d})", .{event.m_hConn});
                        }
                        self.?.addConnection(event.m_hConn);
                        try self.?.packets.pushEvent(gpa, .{ .connected = event.m_hConn });
                    },
                    .k_ESteamNetworkingConnectionState_ClosedByPeer,
                    .k_ESteamNetworkingConnectionState_ProblemDetectedLocally,
                    => {
                        if (socket) |s| _ = s.CloseConnection(event.m_hConn, 0, "peer-closed", false);
                        if (event.m_hConn == self.?.host_conn) {
                            self.?.host_state = .left;
                            std.log.info("host disconnected, shutting down", .{});
                        }
                        self.?.removeConnection(event.m_hConn);
                        try self.?.packets.pushEvent(gpa, .{ .disconnected = event.m_hConn });
                    },
                    else => {},
                }
                return msg.m_iCallback;
            },
            else => return msg.m_iCallback,
        }
    }
    return -1;
}

fn addConnection(self: *Server, conn: steam.HSteamNetConnection) void {
    for (&self.connections) |*slot| {
        if (slot.* == 0) {
            slot.* = conn;
            return;
        }
    }
    std.log.err("connection table full; dropping conn={d}", .{conn});
}

fn removeConnection(self: *Server, conn: steam.HSteamNetConnection) void {
    for (&self.connections) |*slot| {
        if (slot.* == conn) {
            slot.* = 0;
            return;
        }
    }
}
