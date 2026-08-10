const Xlib = @This();

const std = @import("std");

const Window = @import("../root.zig");

display: *xlib.Display,
procs: xlib.ProcTable,
xi_procs: xi.ProcTable,
xi_extension: ?xlib.ExtensionQuery,
window: xlib.Window,

/// X Input Method,
xim: *xlib.XIM,
/// X Input Context,
xic: *xlib.XIC,

atoms: Atoms,

invisible_cursor: xlib.Cursor,
pointer: struct {
    position: Position = .{},
    previous_position: ?Position = null,

    const Position = @FieldType(Window.Pointer.Movement, "position");
} = .{},

pub const Atoms = struct {
    WM_DELETE_WINDOW: xlib.Atom,

    _NET_WM_NAME: xlib.Atom,
    UTF8_STRING: xlib.Atom,

    _NET_WM_STATE: xlib.Atom,
    _NET_WM_STATE_MAXIMIZED_HORZ: xlib.Atom,
    _NET_WM_STATE_MAXIMIZED_VERT: xlib.Atom,
    _NET_WM_STATE_FULLSCREEN: xlib.Atom,
};

pub fn open(self: *Xlib, window: *Window, options: Window.OpenOptions) !void {
    const procs: xlib.ProcTable = try .load();
    const xi_procs: xi.ProcTable = try .load();

    const display = procs.XOpenDisplay.?(null) orelse return error.OpenDisplay;
    errdefer _ = procs.XCloseDisplay.?(display);

    const screen = procs.XDefaultScreen.?(display);
    const root = procs.XRootWindow.?(display, screen);

    var xi_extension: ?xlib.ExtensionQuery = .{};
    if (procs.XQueryExtension.?(
        display,
        xi.extension_name,
        &xi_extension.?.opcode,
        &xi_extension.?.first_event,
        &xi_extension.?.first_error,
    ) == 0) xi_extension = null;

    if (xi_extension != null) {
        var xi_version: xi.VersionQuery = .{ .major = 2, .minor = 0 };
        const xi_enabled = if (xi_procs.XIQueryVersion) |XIQueryVersion|
            XIQueryVersion(display, &xi_version.major, &xi_version.minor) == 0
        else
            false;

        if (!xi_enabled) xi_extension = null;
    }

    const window_handle = procs.XCreateSimpleWindow.?(
        display,
        root,
        if (options.position) |position| position.x else 0,
        if (options.position) |position| position.y else 0,
        @truncate(options.size.width),
        @truncate(options.size.height),
        0,
        0,
        0,
    );

    const event_mask: xlib.Event.Mask = .{
        .exposure = true,
        .structure_notify = true,
        .focus_change = true,

        .enter_window = true,
        .pointer_motion = xi_extension == null, // use xinput motion instead
        .button_press = true,
        .button_release = true,

        .key_press = true,
        .key_release = true,
    };

    _ = procs.XSelectInput.?(
        display,
        window_handle,
        event_mask,
    );

    if (xi_extension != null) {
        var mask = xi.Event.createMask(&.{
            .motion,
        });

        var event_masks = [_]xi.Event.Mask{
            .{
                .device_id = @intFromEnum(xi.DeviceSelector.all_devices),
                .mask_len = mask.len,
                .mask = &mask,
            },
        };

        const result = xi_procs.XISelectEvents.?(display, window_handle, &event_masks, @intCast(event_masks.len));
        if (result != 0) return error.XInputSelectEvents;
    }

    _ = procs.XMapWindow.?(display, window_handle);

    const xim = procs.XOpenIM.?(
        display,
        null,
        null,
        null,
    ) orelse return error.OpenInputMethod;
    errdefer _ = procs.XCloseIM.?(xim);

    const xic = procs.XCreateIC.?(
        xim,
        xlib.XN.InputStyle,
        @as(c_ulong, xlib.XIM.PreeditNothing | xlib.XIM.StatusNothing),

        xlib.XN.ClientWindow,
        window_handle.id,

        xlib.XN.FocusWindow,
        window_handle.id,

        @as(?*anyopaque, null),
    ) orelse return error.CreateInputContext;
    errdefer _ = procs.XDestroyIC.?(self.xic);

    var atoms: Atoms = undefined;
    inline for (std.meta.fields(Atoms)) |field| {
        @field(atoms, field.name) = procs.XInternAtom.?(display, field.name.ptr, xlib.FALSE);
    }

    _ = procs.XSetWMProtocols.?(
        display,
        window_handle,
        &atoms.WM_DELETE_WINDOW,
        1,
    );

    const data = [_]u8{0};
    const empty_bitmap = procs.XCreateBitmapFromData.?(
        display,
        root,
        @ptrCast(&data),
        1,
        1,
    );
    defer _ = procs.XFreePixmap.?(display, empty_bitmap);

    var color = std.mem.zeroes(xlib.Color);

    const invisible_cursor = procs.XCreatePixmapCursor.?(
        display,
        empty_bitmap,
        empty_bitmap,
        &color,
        &color,
        0,
        0,
    );
    errdefer procs.XFreeCursor.?(display, invisible_cursor);

    self.* = .{
        .display = display,
        .procs = procs,
        .xi_procs = xi_procs,
        .xi_extension = xi_extension,
        .window = window_handle,
        .xim = xim,
        .xic = xic,
        .atoms = atoms,
        .invisible_cursor = invisible_cursor,
    };

    try self.setTitle(window, options.title);
}

pub fn close(self: *Xlib, _: *Window) void {
    const display = self.display;

    _ = self.procs.XFreeCursor.?(display, self.invisible_cursor);
    _ = self.procs.XDestroyIC.?(self.xic);
    _ = self.procs.XCloseIM.?(self.xim);
    _ = self.procs.XDestroyWindow.?(display, self.window);
    _ = self.procs.XCloseDisplay.?(display);

    self.xi_procs.unload();
    self.procs.unload();
}

pub fn poll(self: *Xlib, window: *Window, options: Window.PollOptions) !void {
    const display = self.display;
    const xi_opcode = if (self.xi_extension) |ext| ext.opcode else 0;

    const pointer = &window.pointer;
    const keyboard = &window.keyboard;

    self.pointer.previous_position = self.pointer.position;

    while (self.procs.XPending.?(display) > 0) {
        var event: xlib.Event = undefined;
        if (self.procs.XNextEvent.?(display, &event) != 0) return error.NextEvent;

        switch (event.type) {
            .client_message => {
                const client = event.client;
                if (client.data.l[0] == @intFromEnum(self.atoms.WM_DELETE_WINDOW)) window.should_close = true;
            },

            .expose => {
                const expose = event.expose;
                const size: Window.Size = .{ .width = @intCast(expose.width), .height = @intCast(expose.height) };

                window.size = size;
            },
            .configure_notify => {
                const configure = event.configure;
                const size: Window.Size = .{ .width = @intCast(configure.width), .height = @intCast(configure.height) };
                const position: Window.Position = .{ .x = @intCast(configure.x), .y = @intCast(configure.y) };
                window.size = size;
                window.position = position;
            },

            .focus_in => {
                self.procs.XSetICFocus.?(self.xic);
                window.focused = true;
            },
            .focus_out => {
                self.procs.XUnsetICFocus.?(self.xic);
                window.focused = false;
            },

            .enter_notify => {
                self.pointer.previous_position = null;
            },
            .motion_notify => {
                const motion = event.motion;

                self.pointer.position = .{
                    .x = @floatFromInt(motion.x),
                    .y = @floatFromInt(motion.y),
                };
            },
            .button_press, .button_release => {
                const b = &pointer.buttons;

                const button = event.button;
                const state = event.type == .button_press;

                switch (button.button) {
                    1 => b.left = state,
                    2 => b.middle = state,
                    3 => b.right = state,
                    4...7 => if (event.type == .button_press) switch (button.button) {
                        4 => pointer.axis.vertical += 1,
                        5 => pointer.axis.vertical -= 1,
                        6 => pointer.axis.horizontal -= 1,
                        7 => pointer.axis.horizontal += 1,
                        else => unreachable,
                    },
                    8 => b.back = state,
                    9 => b.forward = state,
                    10 => b.extra1 = state,
                    11 => b.extra2 = state,
                    12 => b.extra3 = state,
                    else => {}, // unknown/extra button
                }
            },
            .key_press => {
                var keysym = self.procs.XLookupKeysym.?(&event.key, 0);
                if (Window.Keyboard.fromXkb(@enumFromInt(keysym))) |key| {
                    keyboard.press(key);
                }

                const writer = options.text orelse continue;

                var buffer: [128]u8 = undefined;
                var lookup: xlib.Lookup = .none;

                const len = self.procs.Xutf8LookupString.?(
                    self.xic,
                    &event.key,
                    &buffer,
                    buffer.len,
                    &keysym,
                    &lookup,
                );

                if (len > 0) switch (lookup) {
                    .chars, .both => {
                        const text = buffer[0..@intCast(len)];
                        for (text) |c| {
                            // filter control characters
                            if (std.ascii.isControl(c)) continue;

                            try writer.writeByte(c);
                        }
                    },
                    else => {},
                };
            },
            .key_release => {
                const keysym = self.procs.XLookupKeysym.?(&event.key, 0);
                const key = Window.Keyboard.fromXkb(@enumFromInt(keysym)) orelse continue;
                keyboard.release(key);
            },
            .generic_event => if (event.generic.extension == xi_opcode) {
                if (self.procs.XGetEventData.?(display, &event.generic) == 0) continue;
                const xi_event: *xi.Event = @ptrCast(@alignCast(event.generic.data.?));

                switch (@as(xi.Event.Type, @enumFromInt(event.generic.evtype))) {
                    .motion => {
                        const motion = xi_event.motion;

                        self.pointer.position = .{
                            .x = motion.event_x,
                            .y = motion.event_y,
                        };
                    },
                    else => {},
                }
            },
            else => {}, // std.log.info("{t}", .{event.type}),
        }
    }

    if (pointer.is_relative) {
        pointer.movement = .{ .relative = .{
            .dx = if (self.pointer.previous_position) |previous| self.pointer.position.x - previous.x else 0,
            .dy = if (self.pointer.previous_position) |previous| self.pointer.position.y - previous.y else 0,
        } };
    } else {
        self.pointer.previous_position = null;
        pointer.movement = .{ .position = self.pointer.position };
    }

    if (pointer.constraint == .locked) {
        const center: Window.Position = .{
            .x = @intCast(@divTrunc(window.size.width, 2)),
            .y = @intCast(@divTrunc(window.size.height, 2)),
        };

        _ = self.procs.XWarpPointer.?(
            display,
            .none,
            self.window,
            0,
            0,
            0,
            0,
            @truncate(center.x),
            @truncate(center.y),
        );

        _ = self.procs.XFlush.?(display);

        self.pointer.position = .{
            .x = @floatFromInt(center.x),
            .y = @floatFromInt(center.y),
        };
    }
}

pub fn setTitle(self: *Xlib, _: *Window, title: [:0]const u8) !void {
    const display = self.display;

    // Modern UTF-8 window title (_NET_WM_NAME)
    _ = self.procs.XChangeProperty.?(
        display,
        self.window,
        self.atoms._NET_WM_NAME,
        self.atoms.UTF8_STRING,
        .@"8",
        .replace,
        title.ptr,
        @intCast(title.len),
    );

    // Legacy ICCCM fallback (WM_NAME / XA_STRING)
    _ = self.procs.XChangeProperty.?(
        display,
        self.window,
        .WM_NAME,
        .STRING,
        .@"8",
        .replace,
        title.ptr,
        @intCast(title.len),
    );

    _ = self.procs.XFlush.?(display);
}

pub fn setMaxSize(self: *Xlib, window: *Window, _: ?Window.Size) !void {
    var hints = std.mem.zeroes(xlib.SizeHints);

    if (window.max_size) |size| {
        hints.flags.max_size = true;
        hints.max_width = @intCast(size.width);
        hints.max_height = @intCast(size.height);
    }

    if (window.min_size) |size| {
        hints.flags.min_size = true;
        hints.min_width = @intCast(size.width);
        hints.min_height = @intCast(size.height);
    }

    self.procs.XSetWMNormalHints.?(
        self.display,
        self.window,
        &hints,
    );
}

pub fn setMinSize(self: *Xlib, window: *Window, size: ?Window.Size) !void {
    try self.setMaxSize(window, size);
}

pub fn minimize(self: *Xlib, _: *Window) !void {
    const screen = self.procs.XDefaultScreen.?(self.display);

    if (self.procs.XIconifyWindow.?(self.display, self.window, screen) == 0) return error.IconifyWindow;

    _ = self.procs.XFlush.?(self.display);
}

pub fn maximize(self: *Xlib, _: *Window) !void {
    self.setWmState(
        self.atoms._NET_WM_STATE_MAXIMIZED_HORZ,
        self.atoms._NET_WM_STATE_MAXIMIZED_VERT,
        1,
    );

    _ = self.procs.XFlush.?(self.display);
}

pub fn restore(self: *Xlib, _: *Window) !void {
    self.setWmState(
        self.atoms._NET_WM_STATE_MAXIMIZED_HORZ,
        self.atoms._NET_WM_STATE_MAXIMIZED_VERT,
        0,
    );

    _ = self.procs.XFlush.?(self.display);
}

pub fn setFullscreen(self: *Xlib, _: *Window, enabled: bool) !void {
    self.setWmState(self.atoms._NET_WM_STATE_FULLSCREEN, .NONE, @intFromBool(enabled));

    _ = self.procs.XFlush.?(self.display);
}

pub fn setPointerVisible(self: *Xlib, _: *Window, visible: bool) !void {
    if (visible)
        _ = self.procs.XUndefineCursor.?(
            self.display,
            self.window,
        )
    else
        _ = self.procs.XDefineCursor.?(
            self.display,
            self.window,
            self.invisible_cursor,
        );

    _ = self.procs.XFlush.?(self.display);
}

pub fn setPointerConstraint(self: *Xlib, _: *Window, constraint: Window.Pointer.Constraint) !void {
    switch (constraint) {
        .none => {
            _ = self.procs.XUngrabPointer.?(self.display, .current);
        },
        .confined, .locked => {
            _ = self.procs.XGrabPointer.?(
                self.display,
                self.window,
                xlib.TRUE,
                .{
                    .pointer_motion = true,
                    .button_press = true,
                    .button_release = true,
                },
                .async,
                .async,
                self.window,
                .none, // cursor
                .current,
            );
        },
    }

    _ = self.procs.XFlush.?(self.display);
}

pub fn setPointerRelative(_: *Xlib, _: *Window, _: bool) !void {}

fn setWmState(self: *Xlib, state1: xlib.Atom, state2: xlib.Atom, action: c_long) void {
    var event: xlib.Event = .{
        .client = .{
            .type = @intFromEnum(xlib.Event.Type.client_message),
            .serial = 0,
            .send_event = xlib.TRUE,
            .display = self.display,
            .window = self.window,
            .message_type = self.atoms._NET_WM_STATE,
            .format = 32,
            .data = .{
                .l = .{
                    action, // 0 remove, 1 add, 2 toggle
                    @intCast(@intFromEnum(state1)),
                    @intCast(@intFromEnum(state2)),
                    1, // source indication: application
                    0,
                },
            },
        },
    };

    const root = self.procs.XRootWindow.?(
        self.display,
        self.procs.XDefaultScreen.?(self.display),
    );

    _ = self.procs.XSendEvent.?(
        self.display,
        root,
        xlib.FALSE,
        .{
            .substructure_redirect = true,
            .substructure_notify = true,
        },
        &event,
    );
}

const xlib = struct {
    pub const Display = opaque {};
    pub const XIM = opaque {
        pub const PreeditNothing: c_long = 0x0008;
        pub const StatusNothing: c_long = 0x0400;
    };
    pub const XrmDatabase = opaque {};
    pub const XIC = opaque {};

    const Xid = packed struct(c_ulong) {
        id: c_ulong,

        pub const none: Xid = .{ .id = 0 };
    };
    pub const Window = Xid;
    pub const Drawable = Xid;
    pub const Time = enum(c_ulong) {
        current = 0,
        _,
    };
    pub const Pixmap = Xid;
    pub const Cursor = Xid;
    pub const KeySym = c_ulong;

    pub const Bool = c_int;
    pub const TRUE: Bool = 1;
    pub const FALSE: Bool = 0;

    pub const Atom = enum(c_ulong) {
        NONE = 0,

        PRIMARY = 1,
        SECONDARY = 2,

        ARC = 3,
        ATOM = 4,
        BITMAP = 5,
        CARDINAL = 6,
        COLORMAP = 7,
        CURSOR = 8,
        CUT_BUFFER0 = 9,
        CUT_BUFFER1 = 10,
        CUT_BUFFER2 = 11,
        CUT_BUFFER3 = 12,
        CUT_BUFFER4 = 13,
        CUT_BUFFER5 = 14,
        CUT_BUFFER6 = 15,
        CUT_BUFFER7 = 16,
        DRAWABLE = 17,
        FONT = 18,
        INTEGER = 19,
        PIXMAP = 20,
        POINT = 21,
        RECTANGLE = 22,
        RESOURCE_MANAGER = 23,
        RGB_COLOR_MAP = 24,
        RGB_BEST_MAP = 25,
        RGB_BLUE_MAP = 26,
        RGB_DEFAULT_MAP = 27,
        RGB_GRAY_MAP = 28,
        RGB_GREEN_MAP = 29,
        RGB_RED_MAP = 30,
        STRING = 31,
        VISUALID = 32,
        WINDOW = 33,
        WM_COMMAND = 34,
        WM_HINTS = 35,
        WM_CLIENT_MACHINE = 36,
        WM_ICON_NAME = 37,
        WM_ICON_SIZE = 38,
        WM_NAME = 39,
        WM_NORMAL_HINTS = 40,
        WM_SIZE_HINTS = 41,
        WM_ZOOM_HINTS = 42,
        MIN_SPACE = 43,
        NORM_SPACE = 44,
        MAX_SPACE = 45,
        END_SPACE = 46,
        SUPERSCRIPT_X = 47,
        SUPERSCRIPT_Y = 48,
        SUBSCRIPT_X = 49,
        SUBSCRIPT_Y = 50,
        UNDERLINE_POSITION = 51,
        UNDERLINE_THICKNESS = 52,
        STRIKEOUT_ASCENT = 53,
        STRIKEOUT_DESCENT = 54,
        ITALIC_ANGLE = 55,
        X_HEIGHT = 56,
        QUAD_WIDTH = 57,
        WEIGHT = 58,
        POINT_SIZE = 59,
        RESOLUTION = 60,
        COPYRIGHT = 61,
        NOTICE = 62,
        FONT_NAME = 63,
        FAMILY_NAME = 64,
        FULL_NAME = 65,
        CAP_HEIGHT = 66,
        WM_CLASS = 67,
        WM_TRANSIENT_FOR = 68,
        _,
    };

    // helper
    pub const ExtensionQuery = struct {
        opcode: c_int = 0,
        first_event: c_int = 0,
        first_error: c_int = 0,
    };

    pub const GrabMode = enum(c_int) {
        sync = 0,
        async = 1,
    };

    pub const GrabStatus = enum(c_int) {
        success = 0,
        already_grabbed = 1,
        invalid_time = 2,
        not_viewable = 3,
        frozen = 4,
    };

    pub const XN = struct {
        pub const InputStyle = "inputStyle";
        pub const ClientWindow = "clientWindow";
        pub const FocusWindow = "focusWindow";
    };

    pub const Lookup = enum(c_int) {
        none = 1,
        chars = 2,
        keysym = 3,
        both = 4,
        overflow = -1,
    };

    pub const PropertyMode = enum(c_int) {
        replace = 0,
        prepend = 1,
        append = 2,
    };

    pub const PropertyFormat = enum(c_int) {
        @"8" = 8,
        @"16" = 16,
        @"32" = 32,
    };

    pub const Color = extern struct {
        pixel: c_ulong = 0,
        red: u16 = 0,
        green: u16 = 0,
        blue: u16 = 0,
        flags: u8 = 0,
        pad: u8 = 0,
    };

    pub const ComposeStatus = extern struct {
        compose_ptr: ?*anyopaque,
        chars_matched: c_int,
    };

    pub const SizeHints = extern struct {
        flags: Flags,
        x: c_int,
        y: c_int,
        width: c_int,
        height: c_int,
        min_width: c_int,
        min_height: c_int,
        max_width: c_int,
        max_height: c_int,
        width_inc: c_int,
        height_inc: c_int,
        min_aspect: Aspect,
        max_aspect: Aspect,
        base_width: c_int,
        base_height: c_int,
        win_gravity: c_int,

        pub const Flags = packed struct(c_long) {
            pad0: u4 = 0,

            position: bool = false,
            size: bool = false,
            min_size: bool = false,
            max_size: bool = false,
            resize_inc: bool = false,
            aspect: bool = false,
            base_size: bool = false,
            win_gravity: bool = false,

            pad1: @Int(.unsigned, @bitSizeOf(c_long) - 12) = 0,
        };

        pub const Aspect = extern struct {
            x: c_int,
            y: c_int,
        };
    };

    pub const Event = extern union {
        type: Type,

        key: Key,
        button: Button,
        motion: Motion,
        crossing: Crossing,
        focus: Focus,
        configure: Configure,
        client: ClientMessage,
        expose: Expose,
        destroy: DestroyWindow,
        map: Map,
        unmap: Unmap,
        generic: Generic,
        unknown: [192]u8,

        pub const Type = enum(c_int) {
            /// Not delivered through XNextEvent; X errors use XErrorEvent
            error_event = 0,
            /// Not an event; protocol reply
            reply = 1,
            key_press = 2,
            key_release = 3,
            button_press = 4,
            button_release = 5,
            motion_notify = 6,
            enter_notify = 7,
            leave_notify = 8,
            focus_in = 9,
            focus_out = 10,
            keymap_notify = 11,
            expose = 12,
            graphics_expose = 13,
            no_expose = 14,
            visibility_notify = 15,
            create_notify = 16,
            destroy_notify = 17,
            unmap_notify = 18,
            map_notify = 19,
            map_request = 20,
            reparent_notify = 21,
            configure_notify = 22,
            configure_request = 23,
            gravity_notify = 24,
            resize_request = 25,
            circulate_notify = 26,
            circulate_request = 27,
            property_notify = 28,
            selection_clear = 29,
            selection_request = 30,
            selection_notify = 31,
            colormap_notify = 32,
            client_message = 33,
            mapping_notify = 34,
            generic_event = 35,
            _,
        };

        pub const Mask = packed struct(c_long) {
            key_press: bool = false,
            key_release: bool = false,
            button_press: bool = false,
            button_release: bool = false,
            enter_window: bool = false,
            leave_window: bool = false,
            pointer_motion: bool = false,
            pointer_motion_hint: bool = false,
            button_1_motion: bool = false,
            button_2_motion: bool = false,
            button_3_motion: bool = false,
            button_4_motion: bool = false,
            button_5_motion: bool = false,
            button_motion: bool = false,
            keymap_state: bool = false,
            exposure: bool = false,
            visibility_change: bool = false,
            structure_notify: bool = false,
            resize_redirect: bool = false,
            substructure_notify: bool = false,
            substructure_redirect: bool = false,
            focus_change: bool = false,
            property_change: bool = false,
            colormap_change: bool = false,
            owner_grab_button: bool = false,

            pad: if (@bitSizeOf(c_ulong) == 32) u7 else u39 = 0,
        };

        pub const Generic = extern struct {
            type: c_int,
            serial: c_ulong,
            send_event: Bool,
            display: *Display,
            extension: c_int,
            evtype: c_int,
            cookie: c_uint,
            data: ?*anyopaque,
        };

        pub const Key = extern struct {
            type: c_int,
            serial: c_ulong,
            send_event: Bool,
            display: *Display,
            window: xlib.Window,
            root: xlib.Window,
            subwindow: xlib.Window,
            time: Time,
            x: c_int,
            y: c_int,
            x_root: c_int,
            y_root: c_int,
            state: c_uint,
            keycode: c_uint,
            same_screen: Bool,
        };

        pub const Button = extern struct {
            type: c_int,
            serial: c_ulong,
            send_event: Bool,
            display: *Display,
            window: xlib.Window,
            root: xlib.Window,
            subwindow: xlib.Window,
            time: Time,
            x: c_int,
            y: c_int,
            x_root: c_int,
            y_root: c_int,
            state: c_uint,
            button: c_uint,
            same_screen: Bool,
        };

        pub const Motion = extern struct {
            type: c_int,
            serial: c_ulong,
            send_event: Bool,
            display: *Display,
            window: xlib.Window,
            root: xlib.Window,
            subwindow: xlib.Window,
            time: Time,
            x: c_int,
            y: c_int,
            x_root: c_int,
            y_root: c_int,
            state: c_uint,
            is_hint: u8,
            same_screen: Bool,
        };

        pub const Crossing = extern struct {
            type: c_int,
            serial: c_ulong,
            send_event: Bool,
            display: *Display,
            window: xlib.Window,
            root: xlib.Window,
            subwindow: xlib.Window,
            time: Time,
            x: c_int,
            y: c_int,
            x_root: c_int,
            y_root: c_int,
            mode: c_int,
            detail: c_int,
            same_screen: Bool,
            focus: Bool,
            state: c_uint,
        };

        pub const Focus = extern struct {
            type: c_int,
            serial: c_ulong,
            send_event: Bool,
            display: *Display,
            window: xlib.Window,
            mode: c_int,
            detail: c_int,
        };

        pub const Configure = extern struct {
            type: c_int,
            serial: c_ulong,
            send_event: Bool,
            display: *Display,
            event: xlib.Window,
            window: xlib.Window,
            x: c_int,
            y: c_int,
            width: c_int,
            height: c_int,
            border_width: c_int,
            above: xlib.Window,
            override_redirect: Bool,
        };

        pub const ClientMessage = extern struct {
            type: c_int,
            serial: c_ulong,
            send_event: Bool,
            display: *Display,
            window: xlib.Window,
            message_type: Atom,
            format: c_int,
            data: extern union {
                b: [20]u8,
                s: [10]i16,
                l: [5]c_long,
            },
        };

        pub const Expose = extern struct {
            type: c_int,
            serial: c_ulong,
            send_event: Bool,
            display: *Display,
            window: xlib.Window,
            x: c_int,
            y: c_int,
            width: c_int,
            height: c_int,
            count: c_int,
        };

        pub const DestroyWindow = extern struct {
            type: c_int,
            serial: c_ulong,
            send_event: Bool,
            display: *Display,
            event: xlib.Window,
            window: xlib.Window,
        };

        pub const Map = extern struct {
            type: c_int,
            serial: c_ulong,
            send_event: Bool,
            display: *Display,
            event: xlib.Window,
            window: xlib.Window,
            override_redirect: Bool,
        };

        pub const Unmap = extern struct {
            type: c_int,
            serial: c_ulong,
            send_event: Bool,
            display: *Display,
            event: xlib.Window,
            window: xlib.Window,
            from_configure: Bool,
        };
    };

    const ProcTable = struct {
        lib: std.DynLib = undefined,

        XOpenDisplay: ?*const fn (?[*:0]const u8) callconv(.c) ?*Display,
        XCloseDisplay: ?*const fn (*Display) callconv(.c) c_int,

        XDefaultScreen: ?*const fn (*Display) callconv(.c) c_int,
        XRootWindow: ?*const fn (*Display, screen: c_int) callconv(.c) xlib.Window,

        XQueryExtension: ?*const fn (
            display: *Display,
            name: [*:0]const u8,
            major_opcode_return: *c_int,
            first_event_return: *c_int,
            first_error_return: *c_int,
        ) callconv(.c) Bool,

        XCreateSimpleWindow: ?*const fn (
            *Display,
            parent: xlib.Window,
            x: c_int,
            y: c_int,
            width: c_uint,
            height: c_uint,
            border_width: c_uint,
            border: c_ulong,
            background: c_ulong,
        ) callconv(.c) xlib.Window,

        XDestroyWindow: ?*const fn (*Display, window: xlib.Window) callconv(.c) c_int,

        XMapWindow: ?*const fn (*Display, window: xlib.Window) callconv(.c) c_int,
        XUnmapWindow: ?*const fn (*Display, window: xlib.Window) callconv(.c) c_int,

        XSelectInput: ?*const fn (*Display, window: xlib.Window, event_mask: Event.Mask) callconv(.c) c_int,

        XChangeProperty: ?*const fn (
            *Display,
            window: xlib.Window,
            property: Atom,
            type: Atom,
            format: PropertyFormat,
            mode: PropertyMode,
            data: [*]const u8,
            nelements: c_int,
        ) callconv(.c) c_int,

        XSetWMNormalHints: ?*const fn (*Display, window: xlib.Window, hints: *SizeHints) callconv(.c) void,

        XIconifyWindow: ?*const fn (*Display, window: xlib.Window, screen_number: c_int) callconv(.c) c_int,

        XNextEvent: ?*const fn (*Display, event_return: *Event) callconv(.c) c_int,
        XPending: ?*const fn (*Display) callconv(.c) c_int,
        XGetEventData: ?*const fn (*Display, cookie: *Event.Generic) callconv(.c) xlib.Bool,
        XFreeEventData: ?*const fn (*Display, cookie: *Event.Generic) callconv(.c) void,
        XSendEvent: ?*const fn (
            *Display,
            destination: xlib.Window,
            propagate: Bool,
            event_mask: Event.Mask,
            event_send: *Event,
        ) callconv(.c) c_int,

        XFlush: ?*const fn (*Display) callconv(.c) c_int,
        XSync: ?*const fn (*Display, discard: Bool) callconv(.c) c_int,

        XInternAtom: ?*const fn (
            *Display,
            atom_name: [*:0]const u8,
            only_if_exists: Bool,
        ) callconv(.c) Atom,

        XSetWMProtocols: ?*const fn (*Display, window: xlib.Window, protocols: *Atom, count: c_int) callconv(.c) c_int,

        XLookupKeysym: ?*const fn (event_key: *Event.Key, index: c_int) callconv(.c) KeySym,

        XOpenIM: ?*const fn (
            *Display,
            db: ?*XrmDatabase,
            res_name: ?[*:0]const u8,
            res_class: ?[*:0]const u8,
        ) callconv(.c) ?*XIM,
        XCloseIM: ?*const fn (im: *XIM) callconv(.c) Bool,

        XCreateIC: ?*const fn (im: *XIM, ...) callconv(.c) ?*XIC,
        XDestroyIC: ?*const fn (ic: *XIC) callconv(.c) void,
        XSetICFocus: ?*const fn (ic: *XIC) callconv(.c) void,
        XUnsetICFocus: ?*const fn (ic: *XIC) callconv(.c) void,
        Xutf8LookupString: ?*const fn (
            ic: *XIC,
            event: *Event.Key,
            buffer: [*]u8,
            bytes_buffer: c_int,
            keysym: *KeySym,
            status: *Lookup,
        ) callconv(.c) c_int,

        XCreateBitmapFromData: ?*const fn (
            *Display,
            drawable: xlib.Window,
            data: [*]const u8,
            width: c_uint,
            height: c_uint,
        ) callconv(.c) xlib.Pixmap,
        XCreatePixmap: ?*const fn (
            *Display,
            drawable: Drawable,
            width: c_uint,
            height: c_uint,
            depth: c_uint,
        ) callconv(.c) xlib.Pixmap,
        XFreePixmap: ?*const fn (*Display, pixmap: xlib.Pixmap) callconv(.c) c_int,

        XCreatePixmapCursor: ?*const fn (
            *Display,
            source: Pixmap,
            mask: Pixmap,
            foreground_color: *Color,
            background_color: *Color,
            x: c_uint,
            y: c_uint,
        ) callconv(.c) Cursor,
        XFreeCursor: ?*const fn (*Display, cursor: Cursor) callconv(.c) void,

        XDefineCursor: ?*const fn (*Display, window: xlib.Window, cursor: Cursor) callconv(.c) c_int,
        XUndefineCursor: ?*const fn (*Display, window: xlib.Window) callconv(.c) c_int,

        XQueryPointer: ?*const fn (
            *Display,
            window: xlib.Window,
            root_return: *xlib.Window,
            child_return: *xlib.Window,
            root_x_return: *c_int,
            root_y_return: *c_int,
            win_x_return: *c_int,
            win_y_return: *c_int,
            mask_return: *c_uint,
        ) callconv(.c) Bool,
        XWarpPointer: ?*const fn (
            *Display,
            src_window: xlib.Window,
            dest_window: xlib.Window,
            src_x: c_int,
            src_y: c_int,
            src_width: c_uint,
            src_height: c_uint,
            dest_x: c_int,
            dest_y: c_int,
        ) callconv(.c) c_int,
        XGrabPointer: ?*const fn (
            *Display,
            grab_window: xlib.Window,
            owner_events: Bool,
            event_mask: Event.Mask,
            pointer_mode: GrabMode,
            keyboard_mode: GrabMode,
            confine_to: xlib.Window,
            cursor: xlib.Cursor,
            time: Time,
        ) callconv(.c) GrabStatus,
        XUngrabPointer: ?*const fn (*Display, time: Time) callconv(.c) c_int,

        fn load() !ProcTable {
            var table: ProcTable = undefined;
            table.lib = std.DynLib.openZ("libX11.so") catch |err| return switch (err) {
                error.FileNotFound => error.LibX11NotInstalled,
                else => err,
            };

            inline for (std.meta.fields(ProcTable)) |field| {
                if (field.type == @FieldType(ProcTable, "lib")) continue;

                @field(table, field.name) = table.lib.lookup(std.meta.Child(field.type), field.name);
            }

            return table;
        }

        fn unload(self: *ProcTable) void {
            self.lib.close();
        }
    };
};

/// Xinput (extension)
const xi = struct {
    pub const extension_name = "XInputExtension";

    pub const DeviceSelector = enum(c_int) {
        all_devices = 0,
        all_master_devices = 1,
    };

    pub const DeviceUse = enum(c_int) {
        master_pointer = 1,
        master_keyboard = 2,
        slave_pointer = 3,
        slave_keyboard = 4,
        floating_slave = 5,
    };

    pub const AnyClassInfo = extern struct {
        type: c_int,
        source_id: c_int,
    };

    pub const DeviceInfo = extern struct {
        device_id: c_int,
        name: [*:0]u8,
        use: DeviceUse,
        attachment: c_int,
        enabled: xlib.Bool,
        num_classes: c_int,
        classes: [*]*AnyClassInfo,
    };
    // helper
    pub const VersionQuery = struct {
        major: c_int,
        minor: c_int,
    };

    pub const ValuatorMask = extern struct {
        mask_len: c_int,
        mask: [*]u8,
    };

    pub const Event = extern union {
        key: Key,
        button: Button,
        motion: Motion,
        raw_key: RawKey,
        raw_button: RawButton,
        raw_motion: RawMotion,
        focus: Focus,

        unknown: [256]u8,

        pub const Type = enum(c_int) {
            device_changed = 1,
            key_press = 2,
            key_release = 3,
            button_press = 4,
            button_release = 5,
            motion = 6,
            enter = 7,
            leave = 8,
            focus_in = 9,
            focus_out = 10,
            hierarchy_changed = 11,
            property_event = 12,
            raw_key_press = 13,
            raw_key_release = 14,
            raw_button_press = 15,
            raw_button_release = 16,
            raw_motion = 17,
            touch_begin = 18,
            touch_update = 19,
            touch_end = 20,
            touch_ownership = 21,
            raw_touch_begin = 22,
            raw_touch_update = 23,
            raw_touch_end = 24,
            touch_cancel = 25,
            touch_class = 26,
            _,
        };

        pub const Mask = extern struct {
            device_id: c_int,
            mask_len: c_int,
            mask: [*]u8,
        };

        pub const Key = extern struct {
            type: c_int,
            serial: c_ulong,
            send_event: xlib.Bool,
            display: *xlib.Display,
            extension: c_int,
            evtype: c_int,

            time: xlib.Time,
            device_id: c_int,
            source_id: c_int,

            detail: c_int,

            root: xlib.Window,
            event: xlib.Window,
            child: xlib.Window,

            root_x: f64,
            root_y: f64,
            event_x: f64,
            event_y: f64,

            valuators: ValuatorMask,
        };

        pub const Button = extern struct {
            type: c_int,
            serial: c_ulong,
            send_event: xlib.Bool,
            display: *xlib.Display,
            extension: c_int,
            evtype: c_int,

            time: xlib.Time,
            device_id: c_int,
            source_id: c_int,

            detail: c_int,

            root: xlib.Window,
            event: xlib.Window,
            child: xlib.Window,

            root_x: f64,
            root_y: f64,
            event_x: f64,
            event_y: f64,

            buttons: ValuatorMask,
            valuators: ValuatorMask,
        };

        pub const Motion = extern struct {
            type: c_int,
            serial: c_ulong,
            send_event: xlib.Bool,
            display: *xlib.Display,
            extension: c_int,
            evtype: c_int,

            time: xlib.Time,
            device_id: c_int,
            source_id: c_int,

            detail: c_int,

            root: xlib.Window,
            event: xlib.Window,
            child: xlib.Window,

            root_x: f64,
            root_y: f64,
            event_x: f64,
            event_y: f64,

            buttons: ValuatorMask,
            valuators: ValuatorMask,
        };

        pub const Focus = extern struct {
            type: c_int,
            serial: c_ulong,
            send_event: xlib.Bool,
            display: *xlib.Display,
            extension: c_int,
            evtype: c_int,

            time: xlib.Time,
            device_id: c_int,
            source_id: c_int,
            mode: c_int,
            detail: c_int,
        };

        pub const RawButton = extern struct {
            type: c_int,
            serial: c_ulong,
            send_event: xlib.Bool,
            display: *xlib.Display,
            extension: c_int,
            evtype: c_int,

            time: xlib.Time,
            device_id: c_int,
            source_id: c_int,
            detail: c_int,
            flags: c_int,

            valuators: ValuatorMask,
            raw_values: [*]f64,
        };

        pub const RawKey = extern struct {
            type: c_int,
            serial: c_ulong,
            send_event: xlib.Bool,
            display: *xlib.Display,
            extension: c_int,
            evtype: c_int,

            time: xlib.Time,
            device_id: c_int,
            source_id: c_int,
            detail: c_int,
            flags: c_int,

            valuators: ValuatorMask,
            raw_values: [*]f64,
        };

        pub const RawMotion = extern struct {
            type: c_int,
            serial: c_ulong,
            send_event: xlib.Bool,
            display: *xlib.Display,
            extension: c_int,
            evtype: c_int,

            time: xlib.Time,
            device_id: c_int,
            source_id: c_int,
            detail: c_int,
            flags: c_int,

            valuators: ValuatorMask,
            raw_values: [*]f64,
        };

        pub fn createMask(comptime events: []const Event.Type) [maskSize(events)]u8 {
            var mask: [maskSize(events)]u8 = @splat(0);
            for (events) |event| setMask(&mask, event);
            return mask;
        }

        fn setMask(mask: []u8, event: Event.Type) void {
            const value: usize = @intCast(@intFromEnum(event));
            const byte = value / 8;

            if (byte >= mask.len) return;

            mask[byte] |= @as(u8, 1) << @intCast(value % 8);
        }

        fn maskSize(comptime events: []const Event.Type) usize {
            var max: usize = 0;
            for (events) |event| max = @max(max, @intFromEnum(event));
            return (max / 8) + 1;
        }
    };

    const ProcTable = struct {
        lib: ?std.DynLib = undefined,

        XIQueryVersion: ?*const fn (*xlib.Display, major_version: *c_int, minor_version: *c_int) callconv(.c) c_int,
        XIQueryDevice: ?*const fn (*xlib.Display, device_id: c_int, device_count: *c_int) callconv(.c) ?*DeviceInfo,
        XIFreeDeviceInfo: ?*const fn (devices: *DeviceInfo) callconv(.c) void,
        XISelectEvents: ?*const fn (*xlib.Display, window: xlib.Window, masks: [*]Event.Mask, num_masks: c_int) callconv(.c) c_int,

        fn load() std.DynLib.Error!ProcTable {
            var table: ProcTable = undefined;
            table.lib = std.DynLib.open("libXi.so.6") catch |err| switch (err) {
                error.FileNotFound => return std.mem.zeroes(ProcTable),
                else => return err,
            };

            inline for (std.meta.fields(ProcTable)) |field| {
                if (field.type == @FieldType(ProcTable, "lib")) continue;

                @field(table, field.name) = table.lib.?.lookup(std.meta.Child(field.type), field.name);
            }

            return table;
        }

        fn unload(self: *ProcTable) void {
            if (self.lib) |*lib| lib.close();
        }
    };
};
