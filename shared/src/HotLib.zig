const std = @import("std");
const Watcher = @import("Watcher.zig");
const DynLib = @import("DynLib.zig").DynLib;

pub fn HotLib(
    comptime ExportTable: type,
    comptime Handle: type,
    comptime probe_symbol: [:0]const u8,
    comptime reload_symbol: [:0]const u8,
) type {
    return struct {
        const Self = @This();

        watcher: Watcher,
        symbols: ExportTable,
        current_generation: usize,

        pub fn init(comptime library_name: []const u8, io: std.Io) !Self {
            var watcher: Watcher = try .init(library_name, probe_symbol);
            try watcher.load(io);
            return .{
                .watcher = watcher,
                .symbols = try resolve(&watcher.dynlib.?),
                .current_generation = 0,
            };
        }

        pub fn deinit(self: *Self, io: std.Io) void {
            self.watcher.deinit(io);
        }

        fn rewound(self: *const Self) bool {
            return self.current_generation != 0;
        }

        fn hasNewBuild(self: *Self, io: std.Io) bool {
            if (self.rewound()) return false;
            return self.watcher.changed(io);
        }

        /// Runs the newest build if there is one. Does nothing while rewound.
        pub fn trySwap(self: *Self, io: std.Io, handle: Handle) !void {
            if (!self.hasNewBuild(io)) return;
            if (!try self.watcher.reload(io)) return;
            try self.commit(handle, &self.watcher.dynlib.?, 0);
        }

        /// Runs an older build: 0 is newest, 1 the previous, back through the ring.
        pub fn rewind(self: *Self, generation: usize, handle: Handle) !void {
            if (generation == self.current_generation) return;
            const dynlib = self.watcher.buildAt(generation) orelse {
                std.log.warn("{s}: no build {d} generations back", .{ self.watcher.source_name, generation });
                return;
            };
            try self.commit(handle, dynlib, generation);
        }

        /// Resolves BEFORE the pre-reload hook, so a library missing an export leaves the
        /// running one untouched rather than half-applying a hook pair.
        fn commit(self: *Self, handle: Handle, dynlib: *DynLib, generation: usize) !void {
            const next = try resolve(dynlib);
            @field(self.symbols, reload_symbol)(handle, true);
            self.symbols = next;
            self.current_generation = generation;
            @field(self.symbols, reload_symbol)(handle, false);
        }

        fn resolve(dynlib: *DynLib) !ExportTable {
            var table: ExportTable = undefined;
            inline for (std.meta.fields(ExportTable)) |field| {
                @field(table, field.name) = dynlib.lookup(field.type, field.name) orelse {
                    std.log.err("missing symbol: {s}", .{field.name});
                    return error.DynlibLookup;
                };
            }
            return table;
        }
    };
}
