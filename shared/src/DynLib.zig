const std = @import("std");
const builtin = @import("builtin");
const tracy = @import("ztracy");

const Backend = switch (builtin.os.tag) {
    .windows => WindowsDynLib,
    else => std.DynLib,
};

pub const DynLib = struct {
    backend: Backend,

    pub fn open(path: []const u8) !DynLib {
        return .{ .backend = Backend.open(path) catch |err| {
            std.log.err("dlopen \"{s}\" failed: {t}: {s}", .{ path, err, lastError() });
            return err;
        } };
    }

    fn lastError() []const u8 {
        if (builtin.os.tag == .windows) return "use GetLastError";
        return std.mem.span(std.c.dlerror() orelse return "(no dlerror)");
    }

    pub fn close(self: *DynLib) void {
        if (tracy.enabled) return;
        self.backend.close();
    }

    pub fn lookup(self: *DynLib, comptime T: type, name: [:0]const u8) ?T {
        return self.backend.lookup(T, name);
    }
};

const WindowsDynLib = struct {
    handle: std.os.windows.HMODULE,

    extern "kernel32" fn LoadLibraryW(path: [*:0]const u16) callconv(.winapi) ?std.os.windows.HMODULE;
    extern "kernel32" fn GetProcAddress(module: std.os.windows.HMODULE, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn FreeLibrary(module: std.os.windows.HMODULE) callconv(.winapi) std.os.windows.BOOL;

    fn open(path: []const u8) !WindowsDynLib {
        var buf: [std.fs.max_path_bytes]u16 = undefined;
        const len = try std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], path);
        buf[len] = 0;
        const handle = LoadLibraryW(buf[0..len :0].ptr) orelse {
            std.log.err("LoadLibraryW \"{s}\": {t}", .{ path, std.os.windows.GetLastError() });
            return error.FileNotFound;
        };
        return .{ .handle = handle };
    }

    fn close(self: *WindowsDynLib) void {
        _ = FreeLibrary(self.handle);
        self.* = undefined;
    }

    fn lookup(self: *WindowsDynLib, comptime T: type, name: [:0]const u8) ?T {
        return @ptrCast(GetProcAddress(self.handle, name.ptr) orelse return null);
    }
};
