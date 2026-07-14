const std = @import("std");
const builtin = @import("builtin");

pub const numz = @import("numz");
pub const net = @import("net.zig");
pub const PlanetKind = @import("planet.zig").PlanetKind;
pub const Planet = @import("planet.zig").Planet;
pub const planetSdf = @import("planet.zig").sdf;
pub const StaticVertex = @import("vertex.zig").StaticVertex;
pub const SkinnedVertex = @import("vertex.zig").SkinnedVertex;

pub const Watcher = @import("Watcher.zig");
pub const DynLib = @import("DynLib.zig").DynLib;
/// Deprecated; use `AssetServer2`.
pub const AssetServer = @import("AssetServer.zig");
pub const AssetServer2 = @import("AssetServer2.zig");
pub const SteamNet = @import("SteamNet.zig");

const inventory = @import("inventory.zig");
/// Deprecated; use `Item2`.
pub const Item = inventory.Item;
pub const Item2 = @import("Item.zig");
pub const Inventory = inventory.Inventory;

pub const entity = @import("entity.zig");

pub const tick_seconds: f32 = 0.0167;
pub const max_entities: usize = 1024;
pub const max_enemies: usize = 100;
pub const max_players: usize = 4;

pub fn CappedList(comptime T: type) type {
    return struct {
        items: []T = &.{},
        buffer: []T = &.{},

        pub const empty: @This() = .{};

        pub fn initCapacity(gpa: std.mem.Allocator, capacity: usize) !@This() {
            const buffer = try gpa.alloc(T, capacity);
            return .{ .items = buffer[0..0], .buffer = buffer };
        }

        pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
            gpa.free(self.buffer);
        }

        pub fn append(self: *@This(), item: T) void {
            if (self.items.len >= self.buffer.len) {
                if (builtin.mode == .Debug) @panic("CappedList full: " ++ @typeName(T));
                std.log.err("append dropped: CappedList({s}) full ({d})", .{ @typeName(T), self.buffer.len });
                return;
            }
            self.buffer[self.items.len] = item;
            self.items.len += 1;
        }

        pub fn swapRemove(self: *@This(), index: usize) T {
            const removed = self.items[index];
            self.items[index] = self.items[self.items.len - 1];
            self.items.len -= 1;
            return removed;
        }

        pub fn clearRetainingCapacity(self: *@This()) void {
            self.items.len = 0;
        }
    };
}

pub fn redirectStderrToFile(io: std.Io, path: []const u8) void {
    const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch return;
    switch (builtin.os.tag) {
        .windows => std.os.windows.peb().ProcessParameters.hStdError = file.handle,
        .linux => _ = std.os.linux.dup2(file.handle, 2),
        else => {},
    }
}

pub const teleporter = struct {
    pub const intertact_distance: f32 = 6;
    pub const charge_distance: f32 = 12;

    pub const State = struct {
        active: bool = false,
        charged: f32 = 0,
        max_charge: f32 = 100,
    };
};

const stats = @import("stats.zig");
pub const Stat = stats.Stat;
pub const Stats = stats.Stats;
