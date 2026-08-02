const Cocoa = @This();

const Window = @import("../Window.zig");

pub fn open(self: *Cocoa, window: *Window, options: Window.OpenOptions) !void {
    _ = options;
    _ = window;
    self.* = .{};
}

pub fn close(self: *Cocoa, window: *Window) void {
    _ = self;
    _ = window;
}

pub fn poll(self: *Cocoa, window: *Window, options: Window.PollOptions) !void {
    _ = self;
    _ = window;
    _ = options;
}

pub fn setTitle(self: *Cocoa, window: *Window, title: [:0]const u8) !void {
    _ = self;
    _ = window;
    _ = title;
}

pub fn minimize(self: *Cocoa, window: *Window) !void {
    _ = self;
    _ = window;
}

pub fn maximize(self: *Cocoa, window: *Window) !void {
    _ = self;
    _ = window;
}

pub fn restore(self: *Cocoa, window: *Window) !void {
    _ = self;
    _ = window;
}

pub fn setFullscreen(self: *Cocoa, window: *Window, enabled: bool) !void {
    _ = self;
    _ = window;
    _ = enabled;
}

pub fn setPointerVisible(self: *Cocoa, window: *Window, visible: bool) !void {
    _ = self;
    _ = window;
    _ = visible;
}

pub fn setPointerConstraint(self: *Cocoa, window: *Window, constraint: Window.Pointer.Constraint) !void {
    _ = self;
    _ = window;
    _ = constraint;
}

pub fn setPointerRelative(self: *Cocoa, window: *Window, enabled: bool) !void {
    _ = self;
    _ = window;
    _ = enabled;
}
