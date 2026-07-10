const std = @import("std");
const steam = @import("steamworks");
const Packets = @import("../SteamNet.zig").Packets;

pub const max_connections: usize = 32;
connections: [max_connections]steam.HSteamNetConnection = @splat(0),

handle_packets_future: std.Io.Future(@typeInfo(@TypeOf(handlePackets)).@"fn".return_type.?),
packet_mutex: std.Io.Mutex = .init,
last_send_result: steam.EResult = .k_EResultOK,

gpa: std.mem.Allocator,
io: std.Io,
pipe: steam.HSteamPipe,
gs: steam.ISteamGameServer,
socket: steam.ISteamNetworkingSockets,
packets: Packets,

pub fn init(gpa: std.mem.Allocator, io: std.Io) !@This() {
    if (!steam.Server.SteamInternal_GameServer_Init(
        0,
        27016,
        27017,
        steam.STEAMGAMESERVER_QUERY_PORT_SHARED,
        steam.EServerMode.eServerModeAuthentication,
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
    gs.LogOnAnonymous();
    gs.SetProduct("3167780");
    gs.SetAdvertiseServerActive(true);

    steam.SteamAPI_ManualDispatch_Init();
    const pipe = steam.SteamGameServer_GetHSteamPipe();

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

    std.log.info("\nSTEAM_ID {d}\n", .{gs.GetSteamID()});

    const sock = steam.SteamGameServerNetworkingSockets_SteamAPI();
    const listen = sock.CreateListenSocketP2P(0, &.{});
    if (listen == 0) return error.ListenFailed;

    return .{
        .gpa = gpa,
        .pipe = pipe,
        .gs = gs,
        .socket = sock,
        .io = io,
        .packets = .{},
        .handle_packets_future = undefined,
    };
}

pub fn deinit(self: *@This()) void {
    steam.Server.SteamGameServer_Shutdown();
    self.packets.deinit(self.gpa);
}

pub fn handlePackets(self: *@This()) !void {
    defer std.log.warn("packet pump exited", .{});
    var last_iteration: std.Io.Timestamp = .now(self.io, .real);
    while (true) {
        const now: std.Io.Timestamp = .now(self.io, .real);
        const gap_milliseconds = @divFloor(last_iteration.durationTo(now).nanoseconds, std.time.ns_per_ms);
        if (gap_milliseconds > 100) std.log.warn("packet pump stalled {d}ms", .{gap_milliseconds});
        last_iteration = now;
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

pub fn recievePackets(self: *@This()) !void {
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

pub fn sendPackets(self: *@This()) !void {
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
    self: ?*@This(),
    gpa: std.mem.Allocator,
    pipe: steam.HSteamPipe,
    sock: ?steam.ISteamNetworkingSockets,
) !i32 {
    steam.SteamAPI_ManualDispatch_RunFrame(pipe);
    var msg: steam.CallbackMsg_t = undefined;
    while (steam.SteamAPI_ManualDispatch_GetNextCallback(pipe, &msg)) {
        defer steam.SteamAPI_ManualDispatch_FreeLastCallback(pipe);
        switch (msg.m_iCallback) {
            102 => return error.SteamServersConnectFailure,
            1221 => {
                const data = msg.data() orelse return msg.m_iCallback;
                const ev = data.SteamNetConnectionStatusChangedCallback;
                std.log.info("server net state: {s} (conn={d})", .{ @tagName(ev.m_info.m_eState), ev.m_hConn });
                switch (ev.m_info.m_eState) {
                    .k_ESteamNetworkingConnectionState_Connecting => {
                        if (sock) |s| {
                            const r = s.AcceptConnection(ev.m_hConn);
                            std.log.info("AcceptConnection -> {s}", .{@tagName(r)});
                        }
                    },
                    .k_ESteamNetworkingConnectionState_Connected => {
                        self.?.addConnection(ev.m_hConn);
                        try self.?.packets.pushEvent(gpa, .{ .connected = ev.m_hConn });
                    },
                    .k_ESteamNetworkingConnectionState_ClosedByPeer,
                    .k_ESteamNetworkingConnectionState_ProblemDetectedLocally,
                    => {
                        if (sock) |s| _ = s.CloseConnection(ev.m_hConn, 0, "peer-closed", false);
                        self.?.removeConnection(ev.m_hConn);
                        try self.?.packets.pushEvent(gpa, .{ .disconnected = ev.m_hConn });
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

fn addConnection(self: *@This(), conn: steam.HSteamNetConnection) void {
    for (&self.connections) |*slot| {
        if (slot.* == 0) {
            slot.* = conn;
            return;
        }
    }
    std.log.err("connection table full; dropping conn={d}", .{conn});
}

fn removeConnection(self: *@This(), conn: steam.HSteamNetConnection) void {
    for (&self.connections) |*slot| {
        if (slot.* == conn) {
            slot.* = 0;
            return;
        }
    }
}
