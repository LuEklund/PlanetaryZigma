const Window = @This();

const native_os = @import("builtin").os.tag;

const std = @import("std");

inner: Inner,

should_close: bool = false,
size: Size,
position: Position,
focused: bool = true,
pointer: Pointer = .{},
keyboard: Keyboard = .{},

pub const Inner = switch (native_os) {
    .linux, .freebsd, .netbsd, .openbsd => union(XdgSessionType) {
        wayland: @import("Window/Wayland.zig"),
        x11: @import("Window/Xlib.zig"),
    },
    .windows => @import("Window/Win32.zig"),
    .macos => @import("Window/Cocoa.zig"),
    else => struct {
        const open = @compileError("unsupported platform");
        const close = @compileError("unsupported platform");
        const poll = @compileError("unsupported platform");
        const setTitle = @compileError("unsupported platform");
        const minimize = @compileError("unsupported platform");
        const maximize = @compileError("unsupported platform");
        const restore = @compileError("unsupported platform");
        const setFullscreen = @compileError("unsupported platform");
        const setPointerVisible = @compileError("unsupported platform");
        const setPointerConstraint = @compileError("unsupported platform");
        const setPointerRelative = @compileError("unsupported platform");
    },
};

const XdgSessionType = enum(u1) {
    wayland,
    x11,

    pub const env = "XDG_SESSION_TYPE";

    pub fn detect(init: std.process.Init.Minimal) ?@This() {
        var args = init.args.iterate();
        _ = args.skip();

        const session = while (args.next()) |arg| {
            const identifier = "--xdg=";
            if (!std.mem.startsWith(u8, arg, identifier)) continue;
            break arg[identifier.len..];
        } else init.environ.getPosix(env) orelse return null;

        return std.meta.stringToEnum(@This(), session) orelse null;
    }
};

pub const Size = packed struct(u64) {
    width: u32 = 0,
    height: u32 = 0,

    pub fn eql(a: Size, b: Size) bool {
        return a.width == b.width and a.height == b.height;
    }

    pub fn aspect(self: Size) f32 {
        return @as(f32, @floatFromInt(self.width)) / @as(f32, @floatFromInt(self.height));
    }

    /// Returns the size components as a tuple.
    /// Can be coerced into @Vector(2, i32) or [2]i32.
    ///
    /// Example:
    /// ```zig
    /// const x, const y = size.xy();
    /// ```
    pub fn xy(self: Size) struct { u32, u32 } {
        return .{ self.width, self.height };
    }
};

pub const Position = packed struct(i64) {
    x: i32 = 0,
    y: i32 = 0,

    pub fn eql(a: Position, b: Position) bool {
        return a.x == b.x and a.y == b.y;
    }

    /// Returns the position components as a tuple.
    /// Can be coerced into @Vector(2, i32) or [2]i32.
    ///
    /// Example:
    /// ```zig
    /// const x, const y = position.xy();
    /// ```
    pub fn xy(self: Position) struct { i32, i32 } {
        return .{ self.x, self.y };
    }
};

pub const Pointer = struct {
    movement: Movement = .{ .position = .{} },
    buttons: Buttons = .{},
    axis: Axis = .{},

    visible: bool = true,
    constraint: Window.Pointer.Constraint = .none,
    is_relative: bool = false,

    pub const Movement = union(enum) {
        position: struct {
            x: f64 = 0,
            y: f64 = 0,
        },
        relative: struct {
            dx: f64 = 0,
            dy: f64 = 0,
        },
    };

    pub const Buttons = packed struct {
        left: bool = false,
        middle: bool = false,
        right: bool = false,

        forward: bool = false,
        back: bool = false,
        extra1: bool = false,
        extra2: bool = false,
        extra3: bool = false,
    };

    /// Horizontal and vertical scroll
    pub const Axis = struct {
        horizontal: f64 = 0,
        vertical: f64 = 0,
    };

    pub const Constraint = enum {
        none,
        confined,
        locked,
    };
};

pub const Keyboard = @import("Window/Keyboard.zig");

pub const OpenOptions = struct {
    app_id: ?[:0]const u8 = null, // e.g "my_app"
    title: [:0]const u8,
    size: Size,
    position: ?Position = null,
};

pub fn open(self: *Window, gpa: std.mem.Allocator, minimal: std.process.Init.Minimal, options: OpenOptions) !void {
    self.inner = switch (native_os) {
        .linux, .freebsd, .netbsd, .openbsd => blk: {
            const session_type = XdgSessionType.detect(minimal) orelse .x11;
            switch (session_type) {
                inline else => |inline_session_type| break :blk @unionInit(Inner, @tagName(inline_session_type), undefined),
            }
        },
        else => undefined,
    };

    self.* = .{
        .inner = self.inner,
        .size = options.size,
        .position = options.position orelse .{ .x = 0, .y = 0 },
    };

    try self.call(.open, if (native_os == .windows) .{ gpa, options } else .{options});
}

pub fn close(self: *Window) void {
    self.call(.close, .{}) catch unreachable;
    self.* = undefined;
}

/// Allows optional outputs, such as receiving text input events.
pub const PollOptions = struct {
    /// Optional writer to receive text input events.
    /// Characters are encoded as UTF-8.
    text: ?*std.Io.Writer = null,
};

/// Processes pending window events and updates the window state for the current frame.
/// Should be called once per frame.
pub fn poll(self: *Window, options: PollOptions) !void {
    if (!self.focused) {
        self.pointer.buttons = .{};
        self.keyboard = .{};
    }

    if (self.pointer.movement == .relative) self.pointer.movement = .{ .relative = .{} };
    self.pointer.axis = .{};

    self.keyboard.progress();
    try self.call(.poll, .{options});
}

pub fn setTitle(self: *Window, title: [:0]const u8) !void {
    try self.call(.setTitle, .{title});
}

pub fn minimize(self: *Window) !void {
    try self.call(.minimize, .{});
}
pub fn maximize(self: *Window) !void {
    try self.call(.maximize, .{});
}
pub fn restore(self: *Window) !void {
    try self.call(.restore, .{});
}

pub fn setFullscreen(self: *Window, enabled: bool) !void {
    try self.call(.setFullscreen, .{enabled});
}

pub fn setPointerVisible(self: *Window, visible: bool) !void {
    if (self.pointer.visible == visible) return;
    self.pointer.visible = visible;
    try self.call(.setPointerVisible, .{visible});
}

pub fn setPointerConstraint(self: *Window, constraint: Pointer.Constraint) !void {
    if (self.pointer.constraint == constraint) return;
    self.pointer.constraint = constraint;
    try self.call(.setPointerConstraint, .{constraint});
}

pub fn setPointerRelative(self: *Window, enabled: bool) !void {
    if (self.pointer.is_relative == enabled) return;
    self.pointer.is_relative = enabled;
    self.pointer.movement = if (enabled) .{ .relative = .{} } else .{ .position = .{} };
    try self.call(.setPointerRelative, .{enabled});
}

fn call(self: *Window, function_name: @EnumLiteral(), args: anytype) !void {
    switch (native_os) {
        .linux, .freebsd, .netbsd, .openbsd => switch (self.inner) {
            inline else => |*inner| {
                const function = @field(@TypeOf(inner.*), @tagName(function_name));
                return @call(.always_inline, function, .{ inner, self } ++ args);
            },
        },
        else => {
            const inner = &self.inner;
            const function = @field(@TypeOf(self.inner), @tagName(function_name));
            return @call(.always_inline, function, .{ inner, self } ++ args);
        },
    }
}
