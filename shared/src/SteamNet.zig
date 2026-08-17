const std = @import("std");
const steam = @import("steamworks");

pub const Server = @import("steamNet/Server.zig");
pub const Client = @import("steamNet/Client.zig");

pub const max_msg_bytes: usize = 1024;
pub const local_server_port: u16 = 27018;

pub const Connection = u32;

pub const SendFlags = enum(i32) {
    unreliable = steam.k_nSteamNetworkingSend_Unreliable,
    unreliable_no_nagle = steam.k_nSteamNetworkingSend_UnreliableNoNagle,
    unreliable_no_delay = steam.k_nSteamNetworkingSend_UnreliableNoDelay,
    reliable = steam.k_nSteamNetworkingSend_Reliable,
    reliable_no_nagle = steam.k_nSteamNetworkingSend_ReliableNoNagle,
};

pub fn allowIpWithoutAuthOption() steam.SteamNetworkingConfigValue_t {
    var option: steam.SteamNetworkingConfigValue_t = undefined;
    option.SetInt32(.k_ESteamNetworkingConfig_IP_AllowWithoutAuth, 1);
    return option;
}

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

pub const send_warn_bytes_per_second: u64 = 131072;

pub fn PacketStats(comptime Packet: type) type {
    return struct {
        counts: [kind_count]u32 = @splat(0),
        bytes: [kind_count]u64 = @splat(0),

        const kind_count = std.meta.fields(std.meta.Tag(Packet)).len;
        const endian = @import("net.zig").endian;

        pub fn record(self: *@This(), message_bytes: []const u8) void {
            if (message_bytes.len < 2) return;
            const tag = std.enums.fromInt(std.meta.Tag(Packet), std.mem.readInt(u16, message_bytes[0..2], endian)) orelse return;
            self.counts[@intFromEnum(tag)] += 1;
            self.bytes[@intFromEnum(tag)] += message_bytes.len;
        }

        pub fn logAndReset(self: *@This(), side: []const u8) void {
            var buffer: [512]u8 = undefined;
            var len: usize = 0;
            var total_bytes: u64 = 0;
            inline for (std.meta.fields(std.meta.Tag(Packet)), 0..) |field, kind| {
                total_bytes += self.bytes[kind];
                if (self.counts[kind] != 0) {
                    const part = std.fmt.bufPrint(buffer[len..], "{s}={d}x/{d}B ", .{ field.name, self.counts[kind], self.bytes[kind] }) catch break;
                    len += part.len;
                }
            }
            std.log.info("{s} send/s: {s}total={d}B", .{ side, buffer[0..len], total_bytes });
            if (total_bytes > send_warn_bytes_per_second) std.log.warn("{s} send rate HIGH: {d}B/s", .{ side, total_bytes });
            self.* = .{};
        }
    };
}

pub fn logConnectionStatus(sockets: steam.ISteamNetworkingSockets, conn: steam.HSteamNetConnection) void {
    var status: steam.SteamNetConnectionRealTimeStatus_t = std.mem.zeroes(steam.SteamNetConnectionRealTimeStatus_t);
    if (sockets.GetConnectionRealTimeStatus(conn, &status, &.{}) != .k_EResultOK) return;
    std.log.info("conn={d} ping={d}ms qual={d:.2}/{d:.2} out={d:.0}pps in={d:.0}pps rate={d}Bps pending={d}u/{d}r unacked={d}", .{
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
