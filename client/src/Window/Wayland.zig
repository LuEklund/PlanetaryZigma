const Wayland = @This();

const std = @import("std");

const Window = @import("../Window.zig");

const wl = @import("wayland").client.wl;
const wp = @import("wayland").client.wp;
const xdg = @import("wayland").client.xdg;
const zxdg = @import("wayland").client.zxdg;
const zwp = @import("wayland").client.zwp;
const xkbcommon = @import("xkbcommon");

window: *Window,

display: *wl.Display,
compositor: *wl.Compositor,
wm_base: *xdg.WmBase,
seat: *wl.Seat,
decoration_manager: ?*zxdg.DecorationManagerV1 = null,
cursor_shape_manager: ?*wp.CursorShapeManagerV1 = null,
pointer_constraints: ?*zwp.PointerConstraintsV1 = null,
relative_pointer_manager: ?*zwp.RelativePointerManagerV1 = null,

pointer: ?*wl.Pointer = null,
keyboard: ?*wl.Keyboard = null,
xkb: struct {
    context: *xkbcommon.Context,
    state: ?*xkbcommon.State = null,
    keymap: ?*xkbcommon.Keymap = null,
    keymap_data: []align(std.heap.page_size_min) u8 = &.{},
    modifiers: packed struct {
        depressed: u32 = 0,
        latched: u32 = 0,
        locked: u32 = 0,
        group: u32 = 0,
    } = .{},
},
repeat_key: RepeatKey = .{},

surface: *wl.Surface,
xdg_surface: *xdg.Surface,
toplevel: *xdg.Toplevel,
toplevel_decoration: ?*zxdg.ToplevelDecorationV1 = null,
cursor_shape_device: ?*wp.CursorShapeDeviceV1 = null,
pointer_constraint: PointerConstraint = .none,
relative_pointer: ?*zwp.RelativePointerV1 = null,

decoration_mode: zxdg.ToplevelDecorationV1.Mode = .client_side,
pointer_visible: bool = true,
pointer_enter_serial: u32 = 0,

poll_options: *const Window.PollOptions = &.{},

const RepeatKey = struct {
    keysym: xkbcommon.Keysym = .NoSymbol,
    buffer: [8]u8 = undefined,
    text_len: usize = 0,

    next_time_ms: u64 = 0,

    info: @FieldType(wl.Keyboard.Event, "repeat_info") = .{
        .rate = 0,
        .delay = 0,
    },

    fn nowMs() u64 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);

        return @as(u64, @intCast(ts.sec)) * 1000 +
            @as(u64, @intCast(ts.nsec)) / 1_000_000;
    }

    pub fn scheduleInitial(self: *RepeatKey) void {
        self.next_time_ms = nowMs() +
            @as(u64, @intCast(self.info.delay));
    }

    pub fn scheduleNext(self: *RepeatKey) void {
        const interval_ms = @max(1, 1000 / self.info.rate);
        self.next_time_ms += interval_ms;
    }

    pub fn isDue(self: *const RepeatKey) bool {
        return nowMs() >= self.next_time_ms;
    }
};

const PointerConstraint = union(enum) {
    none: void,
    confined: ?*zwp.ConfinedPointerV1,
    locked: ?*zwp.LockedPointerV1,
};

pub fn open(self: *Wayland, window: *Window, options: Window.OpenOptions) !void {
    try Loader.load();

    self.window = window;
    self.repeat_key = .{};

    const display = try wl.Display.connect(null);

    const registry = try display.getRegistry();
    defer registry.destroy();

    var registry_data: RegistryData = .{};
    registry.setListener(*RegistryData, RegistryData.listener, &registry_data);
    if (display.roundtrip() != .SUCCESS) return error.Roundtrip;

    const compositor = registry_data.compositor.?;
    const wm_base = registry_data.xdg_wm_base.?;
    const seat = registry_data.seat.?;
    const decoration_manager = registry_data.zxdg_decoration_manager;
    const cursor_shape_manager = registry_data.wp_cursor_shape_manager;
    const pointer_constraints = registry_data.zwp_pointer_constraints;
    const relative_pointer_manager = registry_data.zwp_relative_pointer_manager;

    wm_base.setListener(?*anyopaque, xdgWmBaseListener, null);
    seat.setListener(*Wayland, seatListener, self);

    const xkb_context = xkbcommon.Context.new(.no_flags) orelse return error.CreateXkbuserdata;
    self.xkb = .{ .context = xkb_context };

    if (display.roundtrip() != .SUCCESS) return error.Roundtrip;

    const surface = try compositor.createSurface();
    const xdg_surface = try wm_base.getXdgSurface(surface);
    const toplevel = try xdg_surface.getToplevel();
    const toplevel_decoration = if (decoration_manager) |manager| try manager.getToplevelDecoration(toplevel) else null;

    var configured: bool = false;
    surface.setListener(*Window, surfaceListener, window);
    xdg_surface.setListener(*bool, xdgSurfaceListener, &configured);
    toplevel.setListener(*Wayland, xdgToplevelListener, self);
    if (toplevel_decoration) |decoration| {
        decoration.setListener(*Wayland, zxdgToplevelDecorationListener, self);
        decoration.setMode(.server_side);
    }

    if (options.app_id) |app_id| toplevel.setAppId(app_id.ptr);
    toplevel.setTitle(options.title.ptr);

    surface.commit();
    while (!configured) if (display.dispatch() != .SUCCESS) return error.Dispatch;

    self.* = .{
        .window = window,
        .display = display,
        .compositor = compositor,
        .wm_base = wm_base,
        .seat = seat,
        .decoration_manager = decoration_manager,
        .cursor_shape_manager = cursor_shape_manager,
        .pointer_constraints = pointer_constraints,
        .relative_pointer_manager = relative_pointer_manager,

        .pointer = self.pointer,
        .keyboard = self.keyboard,
        .xkb = self.xkb,
        .repeat_key = self.repeat_key,

        .surface = surface,
        .xdg_surface = xdg_surface,
        .toplevel = toplevel,
        .toplevel_decoration = toplevel_decoration,
    };
}

pub fn close(self: *Wayland, window: *Window) void {
    _ = window;

    if (self.cursor_shape_device) |cursor_shape_device| cursor_shape_device.destroy();
    if (self.pointer) |pointer| pointer.destroy();
    if (self.keyboard) |keyboard| keyboard.destroy();
    if (self.xkb.state) |state| state.unref();
    if (self.xkb.keymap) |keymap| keymap.unref();
    self.xkb.context.unref();

    self.toplevel.destroy();
    self.xdg_surface.destroy();
    self.surface.destroy();

    self.display.disconnect();

    Loader.unload();
}

pub fn poll(self: *Wayland, window: *Window, options: Window.PollOptions) !void {
    const display = self.display;

    if (window.should_close) return;

    self.poll_options = &options;

    while (display.prepareRead() == false) {
        if (display.dispatchPending() != .SUCCESS) return error.DispatchPending;
    }

    switch (display.flush()) {
        .SUCCESS, .AGAIN, .INTR => {},
        .PIPE => return error.CompositorDisconnected,
        else => return error.Flush,
    }

    var pfd: std.posix.pollfd = .{
        .fd = @intCast(display.getFd()),
        .events = std.posix.POLL.IN,
        .revents = 0,
    };

    if (std.posix.poll(@ptrCast(&pfd), 1) catch 0 > 0) {
        if (display.readEvents() != .SUCCESS) return error.ReadEvents;
    } else {
        display.cancelRead();
    }

    if (display.dispatchPending() != .SUCCESS) return error.DispatchPending;

    const writer = options.text orelse return;

    if (self.repeat_key.keysym == .NoSymbol or self.repeat_key.text_len == 0 or self.repeat_key.info.rate <= 0) return;

    const now_ms = RepeatKey.nowMs();
    if (now_ms < self.repeat_key.next_time_ms) return;

    const interval_ms = @max(
        @as(u64, 1),
        @as(u64, @intCast(@divTrunc(1000, self.repeat_key.info.rate))),
    );

    const count: usize = @intCast((now_ms - self.repeat_key.next_time_ms) / interval_ms + 1);

    const text = self.repeat_key.buffer[0..self.repeat_key.text_len];

    var data = [_][]const u8{text};
    try writer.writeSplatAll(&data, count);

    self.repeat_key.next_time_ms += @as(u64, count) * interval_ms;
}

pub fn setTitle(self: *Wayland, _: *Window, title: [:0]const u8) !void {
    self.toplevel.setTitle(title);
}

pub fn setMaxSize(self: *Wayland, _: *Window, size: ?Window.Size) !void {
    const max_size: Window.Size = size orelse .{};
    self.toplevel.setMaxSize(@intCast(max_size.width), @intCast(max_size.height));
}

pub fn setMinSize(self: *Wayland, _: *Window, size: ?Window.Size) !void {
    const min_size: Window.Size = size orelse .{};
    self.toplevel.setMinSize(@intCast(min_size.width), @intCast(min_size.height));
}

pub fn minimize(self: *Wayland, _: *Window) !void {
    self.toplevel.setMinSizeimized();
}

pub fn maximize(self: *Wayland, _: *Window) !void {
    self.toplevel.setMaxSizeimized();
}

pub fn restore(self: *Wayland, _: *Window) !void {
    self.toplevel.unsetMaxSizeimized();
}

pub fn setFullscreen(self: *Wayland, _: *Window, enabled: bool) !void {
    if (enabled)
        self.toplevel.setFullscreen(null)
    else
        self.toplevel.unsetFullscreen();
}

pub fn setPointerVisible(self: *Wayland, _: *Window, visible: bool) !void {
    const pointer = self.pointer orelse return;

    self.pointer_visible = visible;

    const serial = self.pointer_enter_serial;
    if (serial == 0) return;

    if (!visible) {
        pointer.setCursor(serial, null, 0, 0);
        return;
    }

    const manager = self.cursor_shape_manager orelse return;

    if (self.cursor_shape_device == null) {
        self.cursor_shape_device = try manager.getPointer(pointer);
    }

    self.cursor_shape_device.?.setShape(serial, .default);
}

pub fn setPointerConstraint(self: *Wayland, window: *Window, constraint: Window.Pointer.Constraint) !void {
    _ = window;

    const pointer = self.pointer orelse return;
    const pointer_constraints = self.pointer_constraints orelse return;

    switch (self.pointer_constraint) {
        .none => {},
        .confined => |confined| if (confined) |p| p.destroy(),
        .locked => |locked| if (locked) |p| p.destroy(),
    }

    switch (constraint) {
        .none => self.pointer_constraint = .none,
        .confined => {
            const confined = try pointer_constraints.confinePointer(
                self.surface,
                pointer,
                null,
                .persistent,
            );

            self.pointer_constraint = .{ .confined = confined };
        },
        .locked => {
            const locked = try pointer_constraints.lockPointer(
                self.surface,
                pointer,
                null,
                .persistent,
            );

            self.pointer_constraint = .{ .locked = locked };
        },
    }
}

pub fn setPointerRelative(self: *Wayland, window: *Window, enabled: bool) !void {
    const pointer = self.pointer orelse return;
    const relative_pointer_manager = self.relative_pointer_manager orelse return;

    if (!enabled) {
        if (self.relative_pointer) |relative| {
            relative.destroy();
            self.relative_pointer = null;
        }
        return;
    }
    if (self.relative_pointer != null) return;

    const relative_pointer = try relative_pointer_manager.getRelativePointer(pointer);
    relative_pointer.setListener(*Window, zwpRelativePointerListener, window);

    self.relative_pointer = relative_pointer;
}

const RegistryData = struct {
    compositor: ?*wl.Compositor = null,
    xdg_wm_base: ?*xdg.WmBase = null,
    seat: ?*wl.Seat = null,
    zxdg_decoration_manager: ?*zxdg.DecorationManagerV1 = null,
    wp_cursor_shape_manager: ?*wp.CursorShapeManagerV1 = null,
    zwp_pointer_constraints: ?*zwp.PointerConstraintsV1 = null,
    zwp_relative_pointer_manager: ?*zwp.RelativePointerManagerV1 = null,

    pub fn listener(registry: *wl.Registry, event: wl.Registry.Event, self: *RegistryData) void {
        switch (event) {
            .global => |global| inline for (std.meta.fields(RegistryData)) |field| {
                const GlobalType = std.meta.Child(std.meta.Child(field.type));
                if (std.mem.orderZ(u8, global.interface, GlobalType.interface.name) == .eq) {
                    @field(self.*, field.name) = registry.bind(global.name, GlobalType, GlobalType.interface.version) catch return;
                    return;
                }
            },
            .global_remove => {},
        }
    }
};

fn xdgWmBaseListener(xdg_wm_base: *xdg.WmBase, event: xdg.WmBase.Event, _: ?*anyopaque) void {
    xdg_wm_base.pong(event.ping.serial);
}

fn seatListener(seat: *wl.Seat, event: wl.Seat.Event, self: *Wayland) void {
    switch (event) {
        .capabilities => |capabilities| {
            if (capabilities.capabilities.pointer) {
                self.pointer = seat.getPointer() catch unreachable;
                self.pointer.?.setListener(*Wayland, pointerListener, self);
            } else if (self.pointer) |pointer| {
                pointer.release();
                self.pointer = null;
            }
            if (capabilities.capabilities.keyboard) {
                self.keyboard = seat.getKeyboard() catch unreachable;
                self.keyboard.?.setListener(*Wayland, keyboardListener, self);
            } else if (self.keyboard) |keyboard| {
                keyboard.release();
                self.keyboard = null;
            }
        },
        .name => {},
    }
}

fn pointerListener(pointer: *wl.Pointer, event: wl.Pointer.Event, self: *Wayland) void {
    const window = self.window;
    switch (event) {
        .enter => |enter| {
            self.pointer_enter_serial = enter.serial;

            if (self.pointer_visible) {
                if (self.cursor_shape_device) |cursor_shape_device| cursor_shape_device.setShape(
                    enter.serial,
                    .default,
                );
            } else pointer.setCursor(
                enter.serial,
                null,
                0,
                0,
            );
        },
        .leave => {},
        .motion => |motion| {
            window.pointer.movement = .{ .position = .{
                .x = motion.surface_x.toDouble(),
                .y = motion.surface_y.toDouble(),
            } };
        },
        .button => |button| {
            const buttons = &window.pointer.buttons;
            const state = button.state == .pressed;
            switch (button.button) {
                0x110 => buttons.left = state,
                0x112 => buttons.middle = state,
                0x111 => buttons.right = state,
                0x113 => buttons.back = state,
                0x114 => buttons.forward = state,
                0x115 => buttons.extra1 = state,
                0x116 => buttons.extra2 = state,
                else => {},
            }
        },
        .axis => |axis| {
            switch (axis.axis) {
                .vertical_scroll => window.pointer.axis.vertical += -axis.value.toDouble() / 10.0,
                .horizontal_scroll => window.pointer.axis.horizontal += axis.value.toDouble() / 10.0,
                _ => unreachable,
            }
        },
    }
}

fn keyboardListener(wl_keyboard: *wl.Keyboard, event: wl.Keyboard.Event, self: *Wayland) void {
    const window = self.window;
    const keyboard = &self.window.keyboard;
    const xkb = &self.xkb;

    switch (event) {
        .keymap => |keymap| {
            defer _ = std.posix.system.close(keymap.fd);
            if (keymap.format != .xkb_v1) return;

            if (xkb.state) |xkb_state| {
                xkb_state.unref();
                xkb.state = null;
            }

            if (xkb.keymap) |xbk_keymap| {
                xbk_keymap.unref();
                xkb.keymap = null;
            }

            if (xkb.keymap_data.len != 0) {
                std.posix.munmap(xkb.keymap_data);
                xkb.keymap_data = &.{};
            }

            xkb.keymap_data = std.posix.mmap(null, keymap.size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, keymap.fd, 0) catch return;
            xkb.keymap = xkbcommon.Keymap.newFromBuffer(xkb.context, xkb.keymap_data.ptr, xkb.keymap_data.len, .text_v1, .no_flags) orelse return;
            xkb.state = xkbcommon.State.new(xkb.keymap.?) orelse return;
            _ = xkb.state.?.updateMask(
                xkb.modifiers.depressed,
                xkb.modifiers.latched,
                xkb.modifiers.locked,
                xkb.modifiers.group,
                0,
                0,
            );
        },
        .modifiers => |modifiers| {
            xkb.modifiers = .{
                .depressed = modifiers.mods_depressed,
                .latched = modifiers.mods_latched,
                .locked = modifiers.mods_locked,
                .group = modifiers.group,
            };
            if (xkb.state == null or xkb.keymap == null) return;

            _ = xkb.state.?.updateMask(modifiers.mods_depressed, modifiers.mods_latched, modifiers.mods_locked, modifiers.group, 0, 0);
        },
        .enter => |enter| {
            window.focused = true;
            for (enter.keys.slice(u32)) |key| {
                const key_event: wl.Keyboard.Event = .{ .key = .{
                    .serial = enter.serial,
                    .time = 0,
                    .key = key,
                    .state = .pressed,
                } };

                keyboardListener(wl_keyboard, key_event, self);
            }
        },
        .leave => window.focused = false,
        .key => |key| {
            if (xkb.state == null or xkb.keymap == null) return;

            const keysym = xkb.state.?.keyGetOneSym(key.key + 8);

            if (self.poll_options.text) |writer| switch (key.state) {
                .pressed => {
                    var buffer: [8]u8 = undefined;
                    const len: usize = @intCast(keysym.toUTF8(&buffer, buffer.len));

                    if (len > 0) {
                        writer.writeAll(buffer[0..len]) catch {};

                        self.repeat_key.keysym = keysym;

                        @memcpy(self.repeat_key.buffer[0..len], buffer[0..len]);
                        self.repeat_key.text_len = len;
                        self.repeat_key.scheduleInitial();
                    }
                },
                .released => {
                    if (self.repeat_key.keysym == keysym) {
                        self.repeat_key.keysym = .NoSymbol;
                        self.repeat_key.text_len = 0;
                    }
                },
                _ => unreachable,
            };

            const k = Window.Keyboard.fromXkb(keysym) orelse return;

            switch (key.state) {
                .pressed => keyboard.press(k),
                .released => keyboard.release(k),
                _ => unreachable,
            }

            // Enter events report keys already held on focus gain with time = 0.
            // Treat them as repeats instead of new key presses.
            if (key.time == 0) keyboard.previous.set(@intFromEnum(k));
        },
        .repeat_info => |repeat_info| {
            self.repeat_key.info = repeat_info;
        },
    }
}

fn surfaceListener(_: *wl.Surface, event: wl.Surface.Event, window: *Window) void {
    _ = window;
    switch (event) {
        .enter => {},
        .leave => {},
    }
}

fn xdgSurfaceListener(xdg_surface: *xdg.Surface, event: xdg.Surface.Event, configured: *bool) void {
    switch (event) {
        .configure => |configure| {
            xdg_surface.ackConfigure(configure.serial);
            configured.* = true;
        },
    }
}

fn xdgToplevelListener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, self: *Wayland) void {
    const window = self.window;

    switch (event) {
        .configure => |configure| {
            for (configure.states.slice(xdg.Toplevel.State)) |state| {
                switch (state) {
                    .activated => window.focused = true,
                    else => {},
                }
            }

            if (configure.width + configure.height == 0) return;

            const size: Window.Size = .{
                .width = @intCast(configure.width),
                .height = @intCast(configure.height),
            };

            window.size = size;
        },
        .close => window.should_close = true,
    }
}

fn zxdgToplevelDecorationListener(_: *zxdg.ToplevelDecorationV1, event: zxdg.ToplevelDecorationV1.Event, self: *Wayland) void {
    self.decoration_mode = event.configure.mode;
}

fn zwpRelativePointerListener(_: *zwp.RelativePointerV1, event: zwp.RelativePointerV1.Event, window: *Window) void {
    switch (event) {
        .relative_motion => |motion| {
            if (window.pointer.movement == .position) window.pointer.movement = .{ .relative = .{} };
            window.pointer.movement.relative.dx += motion.dx_unaccel.toDouble();
            window.pointer.movement.relative.dy += motion.dy_unaccel.toDouble();
        },
    }
}

var loader: Loader = .{};
/// Loads the wayland-client at runtime
const Loader = struct {
    lib: std.DynLib = undefined,

    wl_display_cancel_read: ?*const fn (display: *wl.Display) callconv(.c) void = null,
    wl_display_connect_to_fd: ?*const fn (fd: c_int) callconv(.c) ?*wl.Display = null,
    wl_display_connect: ?*const fn (name: ?[*:0]const u8) callconv(.c) ?*wl.Display = null,
    wl_display_create_queue: ?*const fn (display: *wl.Display) callconv(.c) ?*wl.EventQueue = null,
    wl_display_disconnect: ?*const fn (display: *wl.Display) callconv(.c) void = null,
    wl_display_dispatch_pending: ?*const fn (display: *wl.Display) callconv(.c) c_int = null,
    wl_display_dispatch_queue_pending: ?*const fn (display: *wl.Display, queue: *wl.EventQueue) callconv(.c) c_int = null,
    wl_display_dispatch_queue: ?*const fn (display: *wl.Display, queue: *wl.EventQueue) callconv(.c) c_int = null,
    wl_display_dispatch: ?*const fn (display: *wl.Display) callconv(.c) c_int = null,
    wl_display_flush: ?*const fn (display: *wl.Display) callconv(.c) c_int = null,
    wl_display_get_error: ?*const fn (display: *wl.Display) callconv(.c) c_int = null,
    wl_display_get_fd: ?*const fn (display: *wl.Display) callconv(.c) c_int = null,
    wl_display_prepare_read_queue: ?*const fn (display: *wl.Display, queue: *wl.EventQueue) callconv(.c) c_int = null,
    wl_display_prepare_read: ?*const fn (display: *wl.Display) callconv(.c) c_int = null,
    wl_display_read_events: ?*const fn (display: *wl.Display) callconv(.c) c_int = null,
    wl_display_roundtrip_queue: ?*const fn (display: *wl.Display, queue: *wl.EventQueue) callconv(.c) c_int = null,
    wl_display_roundtrip: ?*const fn (display: *wl.Display) callconv(.c) c_int = null,
    wl_event_queue_destroy: ?*const fn (queue: *wl.EventQueue) callconv(.c) void = null,
    wl_proxy_add_dispatcher: ?*const fn (proxy: *wl.Proxy, dispatcher: *const wl.Proxy.DispatcherFn, implementation: ?*const anyopaque, data: ?*anyopaque) callconv(.c) c_int = null,
    wl_proxy_create: ?*const fn (factory: *wl.Proxy, interface: *const wl.Interface) callconv(.c) ?*wl.Proxy = null,
    wl_proxy_destroy: ?*const fn (proxy: *wl.Proxy) callconv(.c) void = null,
    wl_proxy_get_id: ?*const fn (proxy: *wl.Proxy) callconv(.c) u32 = null,
    wl_proxy_get_user_data: ?*const fn (proxy: *wl.Proxy) callconv(.c) ?*anyopaque = null,
    wl_proxy_get_version: ?*const fn (proxy: *wl.Proxy) callconv(.c) u32 = null,
    wl_proxy_marshal_array_constructor_versioned: ?*const fn (proxy: *wl.Proxy, opcode: u32, args: [*]wl.Argument, interface: *const wl.Interface, version: u32) callconv(.c) ?*wl.Proxy = null,
    wl_proxy_marshal_array_constructor: ?*const fn (proxy: *wl.Proxy, opcode: u32, args: [*]wl.Argument, interface: *const wl.Interface) callconv(.c) ?*wl.Proxy = null,
    wl_proxy_marshal_array: ?*const fn (proxy: *wl.Proxy, opcode: u32, args: ?[*]wl.Argument) callconv(.c) void = null,
    wl_proxy_set_queue: ?*const fn (proxy: *wl.Proxy, queue: *wl.EventQueue) callconv(.c) void = null,

    comptime {
        _ = exports;
    }

    const exports = struct {
        // zig fmt: off
        export fn wl_display_cancel_read(display: *wl.Display) void { loader.wl_display_cancel_read.?(display); }
        export fn wl_display_connect_to_fd(fd: c_int) ?*wl.Display { return loader.wl_display_connect_to_fd.?(fd); }
        export fn wl_display_connect(name: ?[*:0]const u8) ?*wl.Display { return loader.wl_display_connect.?(name); }
        export fn wl_display_create_queue(display: *wl.Display) ?*wl.EventQueue { return loader.wl_display_create_queue.?(display); }
        export fn wl_display_disconnect(display: *wl.Display) void { loader.wl_display_disconnect.?(display); }
        export fn wl_display_dispatch_pending(display: *wl.Display) c_int { return loader.wl_display_dispatch_pending.?(display); }
        export fn wl_display_dispatch_queue_pending(display: *wl.Display, queue: *wl.EventQueue) c_int { return loader.wl_display_dispatch_queue_pending.?(display, queue); }
        export fn wl_display_dispatch_queue(display: *wl.Display, queue: *wl.EventQueue) c_int { return loader.wl_display_dispatch_queue.?(display, queue); }
        export fn wl_display_dispatch(display: *wl.Display) c_int { return loader.wl_display_dispatch.?(display); }
        export fn wl_display_flush(display: *wl.Display) c_int { return loader.wl_display_flush.?(display); }
        export fn wl_display_get_error(display: *wl.Display) c_int { return loader.wl_display_get_error.?(display); }
        export fn wl_display_get_fd(display: *wl.Display) c_int { return loader.wl_display_get_fd.?(display); }
        export fn wl_display_prepare_read_queue(display: *wl.Display, queue: *wl.EventQueue) c_int { return loader.wl_display_prepare_read_queue.?(display, queue); }
        export fn wl_display_prepare_read(display: *wl.Display) c_int { return loader.wl_display_prepare_read.?(display); }
        export fn wl_display_read_events(display: *wl.Display) c_int { return loader.wl_display_read_events.?(display); }
        export fn wl_display_roundtrip_queue(display: *wl.Display, queue: *wl.EventQueue) c_int { return loader.wl_display_roundtrip_queue.?(display, queue); }
        export fn wl_display_roundtrip(display: *wl.Display) c_int { return loader.wl_display_roundtrip.?(display); }
        export fn wl_event_queue_destroy(queue: *wl.EventQueue) void { loader.wl_event_queue_destroy.?(queue); }
        export fn wl_proxy_add_dispatcher(proxy: *wl.Proxy, dispatcher: *const wl.Proxy.DispatcherFn, implementation: ?*const anyopaque, data: ?*anyopaque) c_int { return loader.wl_proxy_add_dispatcher.?(proxy, dispatcher, implementation, data); }
        export fn wl_proxy_create(factory: *wl.Proxy, interface: *const wl.Interface) ?*wl.Proxy { return loader.wl_proxy_create.?(factory, interface); }
        export fn wl_proxy_destroy(proxy: *wl.Proxy) void { loader.wl_proxy_destroy.?(proxy); }
        export fn wl_proxy_get_id(proxy: *wl.Proxy) u32 { return loader.wl_proxy_get_id.?(proxy); }
        export fn wl_proxy_get_user_data(proxy: *wl.Proxy) ?*anyopaque { return loader.wl_proxy_get_user_data.?(proxy); }
        export fn wl_proxy_get_version(proxy: *wl.Proxy) u32 { return loader.wl_proxy_get_version.?(proxy); }
        export fn wl_proxy_marshal_array_constructor_versioned(proxy: *wl.Proxy, opcode: u32, args: [*]wl.Argument, interface: *const wl.Interface, version: u32) ?*wl.Proxy { return loader.wl_proxy_marshal_array_constructor_versioned.?(proxy, opcode, args, interface, version); }
        export fn wl_proxy_marshal_array_constructor(proxy: *wl.Proxy, opcode: u32, args: [*]wl.Argument, interface: *const wl.Interface) ?*wl.Proxy { return loader.wl_proxy_marshal_array_constructor.?(proxy, opcode, args, interface); }
        export fn wl_proxy_marshal_array(proxy: *wl.Proxy, opcode: u32, args: ?[*]wl.Argument) void { loader.wl_proxy_marshal_array.?(proxy, opcode, args); }
        export fn wl_proxy_set_queue(proxy: *wl.Proxy, queue: *wl.EventQueue) void { loader.wl_proxy_set_queue.?(proxy, queue); }
        // zig fmt: on
    };

    fn load() !void {
        loader.lib = try .openZ("libwayland-client.so.0");
        inline for (std.meta.fields(@This())) |field| {
            if (field.type != std.DynLib) {
                @field(loader, field.name) = loader.lib.lookup(field.type, field.name) orelse @panic(field.name);
            }
        }
    }

    fn unload() void {
        loader.lib.close();
    }
};
