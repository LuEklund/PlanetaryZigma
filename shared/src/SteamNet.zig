const std = @import("std");
const steam = @import("steamworks");

pub const Server = @import("steamNet/Server.zig");
pub const Client = @import("steamNet/Client.zig");

/// Mirrors steam.HSteamNetConnection (u32). Defined locally so the dynlib
/// doesn't need to import the steamworks package.
pub const max_msg_bytes: usize = 1024;

pub const Connection = u32;

pub const SendFlags = enum(i32) {
    unreliable = steam.k_nSteamNetworkingSend_Unreliable,
    unreliable_no_nagle = steam.k_nSteamNetworkingSend_UnreliableNoNagle,
    unreliable_no_delay = steam.k_nSteamNetworkingSend_UnreliableNoDelay,
    reliable = steam.k_nSteamNetworkingSend_Reliable,
    reliable_no_nagle = steam.k_nSteamNetworkingSend_ReliableNoNagle,
};

pub const Message = struct {
    conn: Connection,
    flags: SendFlags = .reliable,
    len: u32,
    bytes: [max_msg_bytes]u8 = undefined,

    pub fn slice(self: *const Message) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Event = union(enum) {
    connected: Connection,
    disconnected: Connection,
};

pub var log_connection_status: bool = false;

pub fn logConnectionStatus(sockets: steam.ISteamNetworkingSockets, conn: steam.HSteamNetConnection) void {
    var status: steam.SteamNetConnectionRealTimeStatus_t = std.mem.zeroes(steam.SteamNetConnectionRealTimeStatus_t);
    if (sockets.GetConnectionRealTimeStatus(conn, &status, &.{}) != .k_EResultOK) return;
    std.log.debug("conn={d} ping={d}ms qual={d:.2}/{d:.2} out={d:.0}pps in={d:.0}pps rate={d}Bps pending={d}u/{d}r unacked={d}", .{
        conn,
        status.m_nPing,
        status.m_flConnectionQualityLocal,
        status.m_flConnectionQualityRemote,
        status.m_flOutPacketsPerSec,
        status.m_flInPacketsPerSec,
        status.m_nSendRateBytesPerSecond,
        status.m_cbPendingUnreliable,
        status.m_cbPendingReliable,
        status.m_cbSentUnackedReliable,
    });
}

pub const Packets = struct {
    incoming: std.ArrayListUnmanaged(Message) = .empty,
    outgoing: std.ArrayListUnmanaged(Message) = .empty,
    events: std.ArrayListUnmanaged(Event) = .empty,

    pub fn deinit(self: *Packets, gpa: std.mem.Allocator) void {
        self.incoming.deinit(gpa);
        self.outgoing.deinit(gpa);
        self.events.deinit(gpa);
    }

    pub fn pushIncoming(self: *Packets, gpa: std.mem.Allocator, conn: Connection, bytes: []const u8) !void {
        const len: u32 = @intCast(@min(bytes.len, max_msg_bytes));
        var msg: Message = .{ .conn = conn, .len = len };
        @memcpy(msg.bytes[0..len], bytes[0..len]);
        try self.incoming.append(gpa, msg);
    }

    pub fn pushOutgoing(self: *Packets, gpa: std.mem.Allocator, conn: Connection, bytes: []const u8, flags: SendFlags) !void {
        const len: u32 = @intCast(@min(bytes.len, max_msg_bytes));
        var msg: Message = .{ .conn = conn, .flags = flags, .len = len };
        @memcpy(msg.bytes[0..len], bytes[0..len]);
        try self.outgoing.append(gpa, msg);
    }

    pub fn pushEvent(self: *Packets, gpa: std.mem.Allocator, event: Event) !void {
        try self.events.append(gpa, event);
    }
};
