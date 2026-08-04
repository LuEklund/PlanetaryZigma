const std = @import("std");
const Watcher = @import("Watcher.zig");
const DynLib = @import("DynLib.zig").DynLib;

/// A hot-reloadable dynamic library plus its resolved symbol table.
///
/// `Table` is a struct of function pointers whose FIELD NAMES are the exported symbol
/// names; that is the whole contract. `Handle` is whatever the exports take as their
/// first argument — the client passes `*anyopaque`, the server passes `*System`.
///
/// Swapping without calling the library's reload hook either side is always a bug, so
/// `swap` is the only door and it calls it for you.
pub fn HotLib(
    comptime Table: type,
    comptime Handle: type,
    comptime probe_symbol: [:0]const u8,
    comptime reload_symbol: [:0]const u8,
) type {
    return struct {
        const Self = @This();

        watcher: Watcher,
        symbols: Table,
        current_generation: usize,

        pub fn init(comptime library_name: []const u8, io: std.Io) !Self {
            var watcher: Watcher = try .init(library_name, probe_symbol, io);
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

        /// `requested` null means "no opinion, carry on" — NOT generation 0, or a caller
        /// polling every frame would yank a rewind back to newest on the next one.
        /// 0 = newest, 1 = the previous build, and so on back through the ring.
        pub fn swap(self: *Self, io: std.Io, requested: ?usize, handle: Handle) !void {
            if (requested) |generation| if (generation != self.current_generation) {
                // Returning to 0 after a rewind goes through the ring too — `changed()`
                // would say "up to date" because the mtime never moved.
                const dynlib = self.watcher.version(generation) orelse {
                    std.log.warn("{s}: no build {d} generations back", .{ self.watcher.source_name, generation });
                    return;
                };
                try self.commit(handle, dynlib, generation);
                return;
            };
            // Only the newest build auto-updates; a deliberate rewind stays put.
            if (self.current_generation != 0) return;

            if (!self.watcher.changed(io)) return;
            if (!try self.watcher.reload(io)) return;
            try self.commit(handle, &self.watcher.dynlib.?, 0);
        }

        /// Resolves BEFORE the pre-reload hook: a library missing an export must leave
        /// the running one untouched, with no half-applied hook pair.
        fn commit(self: *Self, handle: Handle, dynlib: *DynLib, generation: usize) !void {
            const next = try resolve(dynlib);
            @field(self.symbols, reload_symbol)(handle, true);
            self.symbols = next;
            self.current_generation = generation;
            @field(self.symbols, reload_symbol)(handle, false);
        }

        fn resolve(dynlib: *DynLib) !Table {
            var table: Table = undefined;
            inline for (std.meta.fields(Table)) |field| {
                @field(table, field.name) = dynlib.lookup(field.type, field.name) orelse {
                    std.log.err("missing symbol: {s}", .{field.name});
                    return error.DynlibLookup;
                };
            }
            return table;
        }
    };
}
