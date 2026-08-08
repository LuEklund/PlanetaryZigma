const Win32 = @This();

// zig build -Dtarget=x86_64-windows && wine zig-out/bin/gravl.exe

const std = @import("std");
const win32 = @import("win32").everything;

const Window = @import("../Window.zig");

gpa: std.mem.Allocator,
hinstance: std.os.windows.HINSTANCE,
class: win32.WNDCLASSEXW,
// class.lpszClassName points into this allocation; freed in close after
// UnregisterClassW, which still reads it.
class_name: [:0]const u16,
hwnd: std.os.windows.HWND,

pending_high_surrogate: ?u16 = null,

fullscreen_data: struct {
    enabled: bool = false,
    style: usize = 0,
    ex_style: usize = 0,
    rect: win32.RECT = std.mem.zeroes(win32.RECT),
} = .{},

pub fn open(self: *Win32, window: *Window, gpa: std.mem.Allocator, options: Window.OpenOptions) anyerror!void {
    const hinstance: std.os.windows.HINSTANCE = @ptrCast(win32.GetModuleHandleW(null) orelse return error.GetInstanceHandle);

    const class_name = try std.unicode.utf8ToUtf16LeAllocZ(gpa, options.app_id orelse "Class");
    errdefer gpa.free(class_name);

    const class = std.mem.zeroInit(win32.WNDCLASSEXW, .{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        .lpszClassName = class_name,
        .lpfnWndProc = wndProc,
        .hInstance = hinstance,
        .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
    });
    errdefer _ = win32.UnregisterClassW(class.lpszClassName, @ptrCast(hinstance));
    check(win32.RegisterClassExW(@ptrCast(&class))) catch return error.RegisterClass;
    const title = try std.unicode.utf8ToUtf16LeAllocZ(gpa, options.title);
    defer gpa.free(title);

    const hwnd = win32.CreateWindowExW(
        .{ .TRANSPARENT = 1 },
        class.lpszClassName,
        @ptrCast(title),
        win32.WS_OVERLAPPEDWINDOW,
        if (options.position) |position| position.x else @max(0, @divTrunc(win32.GetSystemMetrics(.CXSCREEN) - @as(i32, @intCast(options.size.width)), 2)),
        if (options.position) |position| position.y else @max(0, @divTrunc(win32.GetSystemMetrics(.CYSCREEN) - @as(i32, @intCast(options.size.height)), 2)),
        @intCast(options.size.width),
        @intCast(options.size.height),
        null,
        null,
        hinstance,
        window,
    ) orelse {
        reportErr();
        return error.CreateWindowFailed;
    };
    errdefer _ = win32.DestroyWindow(hwnd);

    _ = win32.ShowWindow(hwnd, .{ .SHOWNORMAL = 1 });
    check(win32.UpdateWindow(hwnd)) catch return error.UpdateWindow;

    var raw_input_device: win32.RAWINPUTDEVICE = .{
        .usUsagePage = 0x01, // Generic desktop controls
        .usUsage = 0x02, // Mouse
        .dwFlags = win32.RIDEV_INPUTSINK,
        .hwndTarget = hwnd,
    };

    check(win32.RegisterRawInputDevices(@ptrCast(&raw_input_device), 1, @sizeOf(win32.RAWINPUTDEVICE))) catch return error.RegisterRawInputDevices;

    self.* = .{
        .gpa = gpa,
        .hinstance = hinstance,
        .class = class,
        .class_name = class_name,
        .hwnd = @ptrCast(hwnd),
    };
}

pub fn close(self: *Win32, window: *Window) void {
    _ = window;
    _ = win32.DestroyWindow(@ptrCast(self.hwnd));
    _ = win32.UnregisterClassW(self.class.lpszClassName, @ptrCast(self.hinstance));
    self.gpa.free(self.class_name);
}

pub fn poll(self: *Win32, window: *Window, options: Window.PollOptions) !void {
    const pointer = &window.pointer;
    var msg: win32.MSG = undefined;
    while (win32.PeekMessageW(&msg, @ptrCast(self.hwnd), 0, 0, .{ .REMOVE = 1 }) == win32.TRUE) {
        _ = win32.TranslateMessage(&msg);
        check(win32.DispatchMessageW(&msg)) catch return error.DispatchMessage;

        switch (msg.message) {
            win32.WM_USER + win32.WM_CLOSE => window.should_close = true,
            win32.WM_USER + win32.WM_SIZE => window.size = .{
                .width = @intCast(@as(u16, @truncate(std.math.cast(u32, msg.lParam) orelse continue))),
                .height = @intCast(@as(u16, @truncate(std.math.cast(u32, msg.lParam >> 16) orelse continue))),
            },
            win32.WM_USER + win32.WM_GETMINMAXINFO => {
                const info: *win32.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(msg.lParam)));

                if (window.max_size) |size| {
                    info.ptMaxTrackSize.x = @intCast(size.width);
                    info.ptMaxTrackSize.y = @intCast(size.height);
                }

                if (window.min_size) |size| {
                    info.ptMinTrackSize.x = @intCast(size.width);
                    info.ptMinTrackSize.y = @intCast(size.height);
                }
            },
            win32.WM_USER + win32.WM_MOVE => window.position = .{
                .x = @intCast(@as(u16, @truncate(std.math.cast(u32, msg.lParam) orelse continue))),
                .y = @intCast(@as(u16, @truncate(std.math.cast(u32, msg.lParam >> 16) orelse continue))),
            },
            win32.WM_USER + win32.WM_SETFOCUS => {
                window.focused = true;
                if (!pointer.visible) _ = win32.ShowCursor(win32.FALSE);
                try self.setPointerConstraint(window, window.pointer.constraint);
            },
            win32.WM_USER + win32.WM_KILLFOCUS => {
                window.focused = false;
                _ = win32.ShowCursor(win32.TRUE);
                check(win32.ClipCursor(null)) catch return error.ClipCursor;
            },

            win32.WM_MOUSEMOVE => if (!pointer.is_relative) {
                const x: f64 = @floatFromInt(@as(u16, @truncate(@as(usize, @bitCast(msg.lParam)))));
                const y: f64 = @floatFromInt(@as(u16, @truncate(@as(usize, @bitCast(msg.lParam)) >> 16)));

                pointer.movement = .{ .position = .{ .x = x, .y = y } };
            },
            win32.WM_INPUT => if (pointer.is_relative) {
                var size: u32 = @sizeOf(win32.RAWINPUT);
                var input: win32.RAWINPUT = undefined;

                check(win32.GetRawInputData(
                    @ptrFromInt(@as(usize, @bitCast(msg.lParam))),
                    win32.RID_INPUT,
                    &input,
                    &size,
                    @sizeOf(win32.RAWINPUTHEADER),
                )) catch return error.GetRawInputData;

                if (input.header.dwType == @intFromEnum(win32.RIM_TYPEMOUSE)) {
                    const mouse = input.data.mouse;

                    if (pointer.movement == .position) {
                        pointer.movement = .{ .relative = .{
                            .dx = @floatFromInt(mouse.lLastX),
                            .dy = @floatFromInt(mouse.lLastY),
                        } };
                    } else {
                        pointer.movement.relative.dx += @floatFromInt(mouse.lLastX);
                        pointer.movement.relative.dy += @floatFromInt(mouse.lLastY);
                    }
                }
            },
            win32.WM_RBUTTONDOWN, win32.WM_MBUTTONDOWN, win32.WM_LBUTTONDOWN, win32.WM_XBUTTONDOWN, win32.WM_RBUTTONUP, win32.WM_MBUTTONUP, win32.WM_LBUTTONUP, win32.WM_XBUTTONUP => {
                const b = &pointer.buttons;
                switch (msg.message) {
                    win32.WM_RBUTTONDOWN => b.right = true,
                    win32.WM_MBUTTONDOWN => b.middle = true,
                    win32.WM_LBUTTONDOWN => b.left = true,

                    win32.WM_RBUTTONUP => b.right = false,
                    win32.WM_MBUTTONUP => b.middle = false,
                    win32.WM_LBUTTONUP => b.left = false,

                    win32.WM_XBUTTONDOWN, win32.WM_XBUTTONUP => |x| x: {
                        const state = x == win32.WM_XBUTTONDOWN;
                        const x_button: u32 = @intCast(((msg.wParam >> 16) & 0xFFFF));
                        break :x switch (x_button) {
                            @bitCast(win32.XBUTTON1) => b.back = state,
                            @bitCast(win32.XBUTTON2) => b.forward = state,
                            else => {},
                        };
                    },
                    else => unreachable,
                }
            },
            win32.WM_MOUSEWHEEL, win32.WM_MOUSEHWHEEL => {
                const delta: isize = @as(i16, @bitCast(@as(u16, @truncate(msg.wParam >> 16)))); // signed high word: up/right > 0, down/left < 0
                const lines: f64 = @floatFromInt(@divTrunc(delta, @as(isize, @intCast(win32.WHEEL_DELTA))));

                switch (msg.message) {
                    win32.WM_MOUSEWHEEL => pointer.axis.vertical += lines,
                    win32.WM_MOUSEHWHEEL => pointer.axis.horizontal += lines,
                    else => unreachable,
                }
            },

            win32.WM_KEYDOWN, win32.WM_KEYUP => {
                const key = Window.Keyboard.fromWin32(msg.wParam, msg.lParam) orelse continue;

                switch (msg.message) {
                    win32.WM_KEYDOWN => window.keyboard.press(key),
                    win32.WM_KEYUP => window.keyboard.release(key),
                    else => unreachable,
                }
            },
            win32.WM_CHAR => if (options.text) |writer| {
                const unit: u16 = @truncate(msg.wParam);
                if (unit >= 0xD800 and unit < 0xDC00) {
                    self.pending_high_surrogate = unit;
                    continue;
                }
                const codepoint: u21 = if (unit >= 0xDC00 and unit < 0xE000) pair: {
                    const high = self.pending_high_surrogate orelse continue;
                    self.pending_high_surrogate = null;
                    break :pair 0x10000 + (@as(u21, high - 0xD800) << 10) + (unit - 0xDC00);
                } else unit;
                self.pending_high_surrogate = null;
                // backspace, enter, escape and friends are key events, not text
                if (codepoint < 0x20 or codepoint == 0x7F) continue;

                var buffer: [4]u8 = undefined;
                const decoded = buffer[0 .. std.unicode.utf8Encode(codepoint, &buffer) catch return error.InvalidCodepoint];
                try writer.writeAll(decoded);
            },
            else => continue,
        }
    }
}

pub fn setTitle(self: *Win32, _: *Window, title: [:0]const u8) !void {
    const title_utf16 = try std.unicode.utf8ToUtf16LeAllocZ(self.gpa, title);
    defer self.gpa.free(title_utf16);
    _ = win32.SetWindowTextW(@ptrCast(self.hwnd), @ptrCast(title_utf16));
}

pub fn setMaxSize(_: *Win32, _: *Window, _: ?Window.Size) !void {}

pub fn setMinSize(_: *Win32, _: *Window, _: ?Window.Size) !void {}

pub fn minimize(self: *Win32, _: *Window) !void {
    _ = win32.ShowWindow(@ptrCast(self.hwnd), win32.SW_MINIMIZE);
}

pub fn maximize(self: *Win32, _: *Window) !void {
    _ = win32.ShowWindow(@ptrCast(self.hwnd), win32.SW_MAXIMIZE);
}

pub fn restore(self: *Win32, _: *Window) !void {
    _ = win32.ShowWindow(@ptrCast(self.hwnd), win32.SW_RESTORE);
}

pub fn setFullscreen(self: *Win32, _: *Window, enabled: bool) !void {
    if (self.fullscreen_data.enabled == enabled)
        return;

    if (enabled) {
        self.fullscreen_data.style = win32.getWindowLongPtrW(@ptrCast(self.hwnd), @intFromEnum(win32.GWL_STYLE));

        self.fullscreen_data.ex_style = win32.getWindowLongPtrW(@ptrCast(self.hwnd), @intFromEnum(win32.GWL_EXSTYLE));

        _ = win32.GetWindowRect(@ptrCast(self.hwnd), &self.fullscreen_data.rect);

        var monitor_info = std.mem.zeroInit(win32.MONITORINFO, .{
            .cbSize = @sizeOf(win32.MONITORINFO),
        });

        const monitor = win32.MonitorFromWindow(@ptrCast(self.hwnd), win32.MONITOR_DEFAULTTONEAREST);

        _ = win32.GetMonitorInfoW(monitor, &monitor_info);

        _ = win32.setWindowLongPtrW(
            @ptrCast(self.hwnd),
            @intFromEnum(win32.GWL_STYLE),
            self.fullscreen_data.style & ~@as(usize, @intCast(@as(u32, @bitCast(win32.WS_OVERLAPPEDWINDOW)))),
        );

        _ = win32.setWindowLongPtrW(@ptrCast(self.hwnd), @intFromEnum(win32.GWL_EXSTYLE), 0);

        _ = win32.SetWindowPos(
            @ptrCast(self.hwnd),
            @ptrFromInt(0),
            monitor_info.rcMonitor.left,
            monitor_info.rcMonitor.top,
            monitor_info.rcMonitor.right - monitor_info.rcMonitor.left,
            monitor_info.rcMonitor.bottom - monitor_info.rcMonitor.top,
            win32.SWP_FRAMECHANGED,
        );

        self.fullscreen_data.enabled = true;
    } else {
        _ = win32.setWindowLongPtrW(@ptrCast(self.hwnd), @intFromEnum(win32.GWL_STYLE), self.fullscreen_data.style);

        _ = win32.setWindowLongPtrW(@ptrCast(self.hwnd), @intFromEnum(win32.GWL_EXSTYLE), self.fullscreen_data.ex_style);

        _ = win32.SetWindowPos(
            @ptrCast(self.hwnd),
            null,
            self.fullscreen_data.rect.left,
            self.fullscreen_data.rect.top,
            self.fullscreen_data.rect.right - self.fullscreen_data.rect.left,
            self.fullscreen_data.rect.bottom - self.fullscreen_data.rect.top,
            .{ .DRAWFRAME = 1, .NOZORDER = 1, .SHOWWINDOW = 1 },
        );

        // _ = win32.RedrawWindow(
        //     @ptrCast(self.hwnd),
        //     null,
        //     null,
        //     .{ .INVALIDATE = 1, .UPDATENOW = 1, .FRAME = 1 },
        // );

        self.fullscreen_data.enabled = false;
    }
}

pub fn setPointerVisible(self: *Win32, _: *Window, visible: bool) void {
    _ = self;
    if (visible) {
        while (win32.ShowCursor(win32.TRUE) < 0) {}
    } else {
        while (win32.ShowCursor(win32.FALSE) >= 0) {}
    }
}

pub fn setPointerConstraint(self: *Win32, _: *Window, constraint: Window.Pointer.Constraint) !void {
    switch (constraint) {
        .none => {
            check(win32.ClipCursor(null)) catch return error.ClipCursor;
        },
        .confined, .locked => {
            var rect: win32.RECT = undefined;

            check(win32.GetClientRect(@ptrCast(self.hwnd), &rect)) catch return error.GetClientRectangle;

            var top_left = win32.POINT{
                .x = rect.left,
                .y = rect.top,
            };

            check(win32.ClientToScreen(@ptrCast(self.hwnd), &top_left)) catch return error.ClientToScreen;

            rect.left = top_left.x;
            rect.top = top_left.y;

            rect.right = top_left.x + (rect.right - rect.left);
            rect.bottom = top_left.y + (rect.bottom - rect.top);

            check(win32.ClipCursor(&rect)) catch return error.ClipCursor;
        },
    }
}

pub fn setPointerRelative(_: *Win32, _: *Window, _: bool) !void {}

fn wndProc(hwnd: win32.HWND, msg: u32, w_param: win32.WPARAM, l_param: win32.LPARAM) callconv(.winapi) win32.LRESULT {
    return switch (msg) {
        win32.WM_KILLFOCUS, win32.WM_CLOSE, win32.WM_SIZE, win32.WM_GETMINMAXINFO, win32.WM_MOVE, win32.WM_SETFOCUS => |wm| {
            check(win32.PostMessageW(hwnd, win32.WM_USER + wm, w_param, l_param)) catch {};
            return 0;
        },
        else => win32.DefWindowProcW(hwnd, msg, w_param, l_param),
    };
}

pub fn check(result: anytype) error{Error}!void {
    if (result >= 0) return;
    reportErr();
    return error.Error;
}

pub fn reportErr() void {
    @branchHint(.unlikely);

    const code = win32.GetLastError();

    var text_buffer: [512:0]u16 = undefined;
    const text_len = win32.FormatMessageW(
        .{ .FROM_SYSTEM = 1, .IGNORE_INSERTS = 1 },
        null,
        @intFromEnum(code),
        0,
        @ptrCast(&text_buffer),
        text_buffer.len,
        null,
    );
    const title = std.unicode.utf8ToUtf16LeStringLiteral("Error\x00");

    _ = win32.MessageBoxW(
        null,
        @ptrCast(text_buffer[0..text_len]),
        @ptrCast(title),
        .{ .ICONHAND = 1 },
    );
}
