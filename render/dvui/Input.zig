const Input = @This();

const std = @import("std");
const dvui = @import("dvui");
const Window = @import("Window");

buttons: Window.Pointer.Buttons,
position: dvui.Point.Physical,

pub fn push(
    self: *Input,
    win: *dvui.Window,
    window: *const Window,
    typed: []const u8,
    keys_owned_by_the_app: []const Window.Keyboard.Key,
) !void {
    const pointer = window.pointer;

    if (pointer.movement == .position) {
        const position: dvui.Point.Physical = .{
            .x = @floatCast(pointer.movement.position.x),
            .y = @floatCast(pointer.movement.position.y),
        };
        if (position.x != self.position.x or position.y != self.position.y) {
            self.position = position;
            _ = try win.addEventMouseMotion(.{ .pt = position });
        }
    }

    inline for (.{
        .{ "left", dvui.enums.Button.left },
        .{ "middle", dvui.enums.Button.middle },
        .{ "right", dvui.enums.Button.right },
    }) |pair| {
        const down = @field(pointer.buttons, pair[0]);
        if (down != @field(self.buttons, pair[0])) {
            _ = try win.addEventMouseButton(pair[1], if (down) .press else .release);
        }
    }
    self.buttons = pointer.buttons;

    if (pointer.axis.vertical != 0)
        _ = try win.addEventMouseWheel(
            @floatCast(pointer.axis.vertical * scroll_pixels_per_notch),
            .vertical,
            null,
        );
    if (pointer.axis.horizontal != 0)
        _ = try win.addEventMouseWheel(
            @floatCast(pointer.axis.horizontal * scroll_pixels_per_notch),
            .horizontal,
            null,
        );

    if (typed.len > 0) _ = try win.addEventText(.{ .text = typed });

    const mod = modifiers(window.keyboard);
    for (0..Window.Keyboard.Key.count) |i| {
        const key: Window.Keyboard.Key = @enumFromInt(i);
        const action: @FieldType(dvui.Event.Key, "action") = switch (window.keyboard.get(key)) {
            .none => continue,
            .press => .down,
            .repeat => .repeat,
            .release => .up,
        };
        if (std.mem.indexOfScalar(
            Window.Keyboard.Key,
            keys_owned_by_the_app,
            key,
        ) != null) continue;
        const code = translate(key) orelse continue;
        _ = try win.addEventKey(.{ .code = code, .action = action, .mod = mod });
    }
}

const scroll_pixels_per_notch = 20.0;

fn modifiers(keyboard: Window.Keyboard) dvui.enums.Mod {
    var mod: u16 = 0;
    if (keyboard.isDown(.left_shift)) mod |= @intFromEnum(dvui.enums.Mod.lshift);
    if (keyboard.isDown(.right_shift)) mod |= @intFromEnum(dvui.enums.Mod.rshift);
    if (keyboard.isDown(.left_control)) mod |= @intFromEnum(dvui.enums.Mod.lcontrol);
    if (keyboard.isDown(.right_control)) mod |= @intFromEnum(dvui.enums.Mod.rcontrol);
    if (keyboard.isDown(.left_alt)) mod |= @intFromEnum(dvui.enums.Mod.lalt);
    if (keyboard.isDown(.right_alt)) mod |= @intFromEnum(dvui.enums.Mod.ralt);
    if (keyboard.isDown(.left_super)) mod |= @intFromEnum(dvui.enums.Mod.lcommand);
    if (keyboard.isDown(.right_super)) mod |= @intFromEnum(dvui.enums.Mod.rcommand);
    return @enumFromInt(mod);
}

fn translate(key: Window.Keyboard.Key) ?dvui.enums.Key {
    return switch (key) {
        .@"0" => .zero,
        .@"1" => .one,
        .@"2" => .two,
        .@"3" => .three,
        .@"4" => .four,
        .@"5" => .five,
        .@"6" => .six,
        .@"7" => .seven,
        .@"8" => .eight,
        .@"9" => .nine,
        .left_super => .left_command,
        .right_super => .right_command,
        .keypad_0 => .kp_0,
        .keypad_1 => .kp_1,
        .keypad_2 => .kp_2,
        .keypad_3 => .kp_3,
        .keypad_4 => .kp_4,
        .keypad_5 => .kp_5,
        .keypad_6 => .kp_6,
        .keypad_7 => .kp_7,
        .keypad_8 => .kp_8,
        .keypad_9 => .kp_9,
        .keypad_add => .kp_add,
        .keypad_subtract => .kp_subtract,
        .keypad_multiply => .kp_multiply,
        .keypad_divide => .kp_divide,
        .keypad_enter => .kp_enter,
        .keypad_decimal => .kp_decimal,
        else => std.meta.stringToEnum(dvui.enums.Key, @tagName(key)),
    };
}
