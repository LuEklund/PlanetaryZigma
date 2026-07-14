const std = @import("std");
const steam = @import("steamworks");
const SteamNet = @import("../SteamNet.zig");
const Packets = SteamNet.Packets;
const ServerListResponse = steam.ISteamMatchmakingServerListResponse;

pub const ServerInfo = extern struct {
    steam_id: u64,
    name: [64]u8,
    id_str: [64]u8,
};
pub const ServerList = extern struct {
    const RefreshState = enum(u8) {
        idle,
        request,
        refreshing,
        done,
    };
    servers: [8]ServerInfo = undefined,
    count: usize = 0,
    refresh_state: RefreshState = .idle,
};

const Browser = extern struct {
    const VTable = extern struct {
        responded: *const fn (*Browser, steam.HServerListRequest, i32) callconv(.c) void,
        failed: *const fn (*Browser, steam.HServerListRequest, i32) callconv(.c) void,
        complete: *const fn (*Browser, steam.HServerListRequest, steam.EMatchMakingServerResponse) callconv(.c) void,
    };
    //NOTE: vtable_ptr only exist cuz of CPP BS.
    vtable: *const VTable = &.{
        .responded = &responded,
        .failed = &failed,
        .complete = &complete,
    },
    list: ServerList = .{},
    request: steam.HServerListRequest = 0,

    fn responded(_: *Browser, request: steam.HServerListRequest, server_index: i32) callconv(.c) void {
        const server = steam.SteamMatchmakingServers().GetServerDetails(request, server_index);
        std.log.info("Server[{d}] steamID={d} name=\"{s}\"", .{
            server_index, server.*.m_steamID, std.mem.sliceTo(server.*.m_szServerName[0..], 0),
        });
    }
    fn failed(_: *Browser, _: steam.HServerListRequest, server_index: i32) callconv(.c) void {
        std.log.info("Server[{d}] Failed to respond", .{
            server_index,
        });
    }
    fn complete(self: *Browser, request: steam.HServerListRequest, response: steam.EMatchMakingServerResponse) callconv(.c) void {
        std.log.info("server list refresh compele: {s}", .{@tagName(response)});
        const servers = steam.SteamMatchmakingServers();
        const server_count = servers.GetServerCount(request);
        std.log.info("refresh complete: {s} ({d} servers)", .{ @tagName(response), server_count });
        self.list.count = @max(@min(server_count, self.list.servers.len), 0);
        for (0..self.list.count) |server_index| {
            const server = servers.GetServerDetails(request, @intCast(server_index));
            self.list.servers[server_index].steam_id = server.*.m_steamID;
            @memcpy(self.list.servers[server_index].name[0..], server.*.m_szServerName[0..]);
            std.log.info("Server[{d}] steamID={d} hadResponse={} name=\"{s}\"", .{
                server_index,
                server.*.m_steamID,
                server.*.m_bHadSuccessfulResponse,
                std.mem.sliceTo(server.*.m_szServerName[0..], 0),
            });
        }
        self.list.refresh_state = .done;
    }
};

handle_packets_future: std.Io.Future(@typeInfo(@TypeOf(handlePackets)).@"fn".return_type.?),
packet_mutex: std.Io.Mutex = .init,

gpa: std.mem.Allocator,
io: std.Io,
user_steam_id: u64,
server_conn: steam.HSteamNetConnection = 0,
own_lobby: u64 = 0,
last_send_result: steam.EResult = .k_EResultOK,
packets: Packets,
pipe: steam.HSteamPipe,
browser: Browser,

pub fn init(gpa: std.mem.Allocator, io: std.Io) !@This() {
    if (!steam.SteamAPI_Init()) {
        std.log.err("SteamAPI_Init failed. Check: Steam is running, you are logged in, and steam_appid.txt exists in the working directory with a valid app id.", .{});
        return error.InitSteamworks;
    }
    steam.SteamAPI_ManualDispatch_Init();
    const steam_pipe = steam.SteamAPI_GetHSteamPipe();

    return .{
        .pipe = steam_pipe,
        .packets = .{},
        .gpa = gpa,
        .handle_packets_future = undefined,
        .io = io,
        .user_steam_id = steam.SteamUser().GetSteamID(),
        .browser = .{},
    };
}

pub fn deinit(self: *@This()) void {
    self.handle_packets_future.cancel(self.io) catch {};

    const servers = steam.SteamMatchmakingServers();
    if (self.browser.request != 0) {
        servers.CancelQuery(self.browser.request);
        servers.ReleaseRequest(self.browser.request);
        self.browser.request = 0;
    }

    //NOTE: drain or SteamAPI_Shutdown segfaults when a conn + server-list query both existed.
    const sockets = steam.SteamNetworkingSockets_SteamAPI();
    const conn = self.server_conn;
    if (conn != 0) {
        // linger=true: flush pending data and send a clean close so the server
        // drops us immediately instead of timing out.
        _ = sockets.CloseConnection(conn, 0, "client-shutdown", true);
        self.server_conn = 0;
    }

    // Pump until the connection is fully torn down -- GetConnectionInfo goes
    // false (handle recycled) or reports None -- so the low-level SDR/ICE
    // sockets are released before SteamAPI_Shutdown. Skipping this races the
    // P2P teardown: shutting down with sockets still open kills the
    // SocketThread mid-flight (exit 5). Cap at ~1s so a stuck relay can't hang.
    var drained: u32 = 0;
    while (drained < 400) : (drained += 1) {
        self.steamPump() catch {};
        // if (conn != 0) {
        //     var info: steam.SteamNetConnectionInfo_t = undefined;
        //     const alive = sockets.GetConnectionInfo(conn, &info);
        //     if (!alive or info.m_eState == .k_ESteamNetworkingConnectionState_None) break;
        // }
        self.io.sleep(.fromMilliseconds(2), .real) catch {};
    }

    steam.SteamAPI_Shutdown();
    self.packets.deinit(self.gpa);
}

pub fn disconnect(self: *@This()) void {
    const sockets = steam.SteamNetworkingSockets_SteamAPI();
    const conn = self.server_conn;
    if (conn != 0) {
        _ = sockets.CloseConnection(conn, 0, "client-main-menu", true);
        self.server_conn = 0;
    }

    self.packets.incoming.clearRetainingCapacity();
    self.packets.outgoing.clearRetainingCapacity();
    self.packets.events.clearRetainingCapacity();
}

pub fn isLoggedOn(self: *const @This()) bool {
    _ = self;
    return steam.SteamUser().BLoggedOn();
}

fn endReasonName(reason: i32) []const u8 {
    return switch (reason) {
        3001 => "Local_OfflineMode",
        3002 => "Local_ManyRelayConnectivity",
        3003 => "Local_HostedServerPrimaryRelay",
        3004 => "Local_NetworkConfig",
        3005 => "Local_Rights",
        3006 => "Local_P2P_ICE_NoPublicAddresses",
        4001 => "Remote_Timeout",
        4002 => "Remote_BadCrypt",
        4003 => "Remote_BadCert",
        4006 => "Remote_BadProtocolVersion",
        4007 => "Remote_P2P_ICE_NoPublicAddresses",
        5001 => "Misc_Generic",
        5002 => "Misc_InternalError",
        5003 => "Misc_Timeout",
        5005 => "Misc_SteamConnectivity",
        5006 => "Misc_NoRelaySessionsToClient",
        5008 => "Misc_P2P_Rendezvous",
        5009 => "Misc_P2P_NAT_Firewall",
        5010 => "Misc_PeerSentNoConnection",
        else => switch (reason) {
            1000...1999 => "App (game-defined close)",
            2000...2999 => "AppException (game-defined crash)",
            3000...3999 => "Local (your side gave up: timeout/config)",
            4000...4999 => "Remote (server closed/timed out)",
            5000...5999 => "Misc (relay/internal)",
            else => "Unknown/Invalid",
        },
    };
}

pub fn handlePackets(self: *@This()) !void {
    defer std.log.warn("packet pump exited", .{});
    var last_iteration: std.Io.Timestamp = .now(self.io, .real);
    var last_status_log = last_iteration;
    while (true) {
        const now: std.Io.Timestamp = .now(self.io, .real);
        const gap_milliseconds = @divFloor(last_iteration.durationTo(now).nanoseconds, std.time.ns_per_ms);
        if (gap_milliseconds > 100) std.log.warn("packet pump stalled {d}ms", .{gap_milliseconds});
        last_iteration = now;
        if (@import("../SteamNet.zig").log_connection_status and self.server_conn != 0 and last_status_log.durationTo(now).nanoseconds > std.time.ns_per_s) {
            last_status_log = now;
            @import("../SteamNet.zig").logConnectionStatus(steam.SteamNetworkingSockets_SteamAPI(), self.server_conn);
        }
        try self.io.checkCancel();
        {
            try self.packet_mutex.lock(self.io);
            defer self.packet_mutex.unlock(self.io);
            self.steamPump() catch |err|
                std.log.err("steamPump: {s}", .{@errorName(err)});
            self.recievePackets() catch |err|
                std.log.err("recievePackets: {s}", .{@errorName(err)});
            self.sendPackets() catch |err|
                std.log.err("sendPackets: {s}", .{@errorName(err)});
            if (self.browser.list.refresh_state == .request) {
                self.browser.list.refresh_state = .refreshing;
                const servers = steam.SteamMatchmakingServers();
                const app_id = steam.SteamUtils().GetAppID();
                std.log.info("requsting internet server list for app {d}...", .{app_id});
                self.browser.request = servers.RequestInternetServerList(app_id, null, 0, @ptrCast(&self.browser));
            }
        }
        try self.io.sleep(.{ .nanoseconds = 1_000_000 }, .real);
    }
}

fn steamPump(self: *@This()) !void {
    steam.SteamAPI_ManualDispatch_RunFrame(self.pipe);
    if (self.browser.list.refresh_state == .done and self.browser.request != 0) {
        const servers = steam.SteamMatchmakingServers();
        servers.ReleaseRequest(self.browser.request);
        self.browser.request = 0;
    }

    var callback: steam.CallbackMsg_t = undefined;
    while (steam.SteamAPI_ManualDispatch_GetNextCallback(self.pipe, &callback)) {
        defer steam.SteamAPI_ManualDispatch_FreeLastCallback(self.pipe);
        const callback_data = callback.data() orelse continue;
        switch (callback_data) {
            .SteamNetConnectionStatusChangedCallback => |status_changed| {
                std.log.info("client net state: {s} (conn={d})", .{ @tagName(status_changed.m_info.m_eState), status_changed.m_hConn });
                switch (status_changed.m_info.m_eState) {
                    .k_ESteamNetworkingConnectionState_Connected => {
                        self.server_conn = status_changed.m_hConn;
                        try self.packets.pushEvent(self.gpa, .{ .connected = status_changed.m_hConn });
                    },
                    .k_ESteamNetworkingConnectionState_ClosedByPeer,
                    .k_ESteamNetworkingConnectionState_ProblemDetectedLocally,
                    => {
                        std.log.warn("client disconnect: state={s} end_reason={d} ({s}) debug=\"{s}\"", .{
                            @tagName(status_changed.m_info.m_eState),
                            status_changed.m_info.m_eEndReason,
                            endReasonName(status_changed.m_info.m_eEndReason),
                            std.mem.sliceTo(&status_changed.m_info.m_szEndDebug, 0),
                        });
                        _ = steam.SteamNetworkingSockets_SteamAPI().CloseConnection(status_changed.m_hConn, 0, "client-close", false);
                        if (self.server_conn == status_changed.m_hConn) self.server_conn = 0;
                        try self.packets.pushEvent(self.gpa, .{ .disconnected = status_changed.m_hConn });
                    },
                    else => {},
                }
            },

            else => {},
        }
    }
}

pub fn recievePackets(self: *@This()) !void {
    const sockets = steam.SteamNetworkingSockets_SteamAPI();

    var messages: [16][*c]steam.SteamNetworkingMessage_t = undefined;
    while (true) {
        const received = sockets.ReceiveMessagesOnConnection(self.server_conn, &messages[0], @intCast(messages.len));
        if (received <= 0) break;
        const received_count: usize = @intCast(received);
        for (messages[0..received_count]) |raw_message| {
            if (raw_message == null) continue;
            const message: *steam.SteamNetworkingMessage_t = raw_message;
            defer message.Release();
            if (message.m_pData == null or message.m_cbSize <= 0) continue;
            const bytes = message.m_pData[0..@intCast(message.m_cbSize)];
            try self.packets.pushIncoming(self.gpa, self.server_conn, bytes);
        }
    }
}

pub fn sendPackets(self: *@This()) !void {
    if (self.packets.outgoing.items.len == 0) return;
    const sockets = steam.SteamNetworkingSockets_SteamAPI();
    for (self.packets.outgoing.items) |*message| {
        var message_number: i64 = 0;
        const result = sockets.SendMessageToConnection(message.conn, message.bytes[0..message.len], @intFromEnum(message.flags), &message_number);
        if (result != self.last_send_result) {
            self.last_send_result = result;
            std.log.warn("send result changed: {t} (conn={d})", .{ result, message.conn });
        }
    }
    self.packets.outgoing.clearRetainingCapacity();
}

pub fn connectToServer(self: *@This(), steam_id: u64) !void {
    var identity: steam.SteamNetworkingIdentity = undefined;
    identity.Clear();
    identity.SetSteamID64(steam_id);
    const conn = steam.SteamNetworkingSockets_SteamAPI().ConnectP2P(&identity, 0, &.{});
    if (conn == 0) {
        std.log.err("ConnectP2P failed for {d}", .{steam_id});
        return;
    }
    self.server_conn = conn;
    std.log.info("ConnectP2P({d}) -> {d}", .{ steam_id, conn });
}

pub fn connectToLocalServer(self: *@This(), port: u16) !void {
    var address: steam.SteamNetworkingIPAddr = undefined;
    address.Clear();
    address.SetIPv4(0x7f000001, port);
    const option = SteamNet.allowIpWithoutAuthOption();
    const conn = steam.SteamNetworkingSockets_SteamAPI().ConnectByIPAddress(&address, &.{option});
    if (conn == 0) {
        std.log.err("ConnectByIPAddress(localhost:{d}) failed", .{port});
        return;
    }
    self.server_conn = conn;
    std.log.info("ConnectByIPAddress(localhost:{d}) -> {d}", .{ port, conn });
}
