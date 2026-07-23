const Chat = @This();

const std = @import("std");
const shared = @import("shared");
const yes = @import("yes");

const KeySym = yes.Window.Event.Key.Sym;

pub const max_lines = 8;
pub const visible_seconds: f32 = 12;
pub const open_key: KeySym = .t;

pub const Line = struct {
    buffer: [shared.max_player_name_len + shared.max_chat_len + 2]u8 = undefined,
    len: usize = 0,
    time: f32 = 0,

    pub fn slice(self: *const Line) []const u8 {
        return self.buffer[0..self.len];
    }
};

lines: [max_lines]Line = [_]Line{.{}} ** max_lines,
pushed: usize = 0,
open: bool = false,
input: [shared.max_chat_len]u8 = undefined,
input_len: usize = 0,
shift: bool = false,
pending: bool = false,

pub fn push(self: *Chat, name: []const u8, message: []const u8, time: f32) void {
    const line = &self.lines[self.pushed % max_lines];
    var writer: std.Io.Writer = .fixed(&line.buffer);
    writer.print("{s}: {s}", .{ name, message }) catch {};
    line.len = writer.end;
    line.time = time;
    self.pushed += 1;
}

pub fn count(self: *const Chat) usize {
    return @min(self.pushed, max_lines);
}

pub fn get(self: *const Chat, index: usize) *const Line {
    return &self.lines[(self.pushed - self.count() + index) % max_lines];
}

pub fn text(self: *const Chat) []const u8 {
    return self.input[0..self.input_len];
}

pub fn handleKey(self: *Chat, key: yes.Window.Event.Key) void {
    switch (key.sym) {
        .left_shift, .right_shift => {
            self.shift = key.state == .pressed;
            return;
        },
        else => {},
    }
    if (key.state != .pressed) return;
    switch (key.sym) {
        .escape => {
            self.input_len = 0;
            self.open = false;
        },
        .enter => {
            self.open = false;
            self.pending = self.input_len != 0;
        },
        .backspace => {
            if (self.input_len > 0) self.input_len -= 1;
        },
        else => {
            if (charFromSym(key.sym, self.shift)) |char| {
                if (self.input_len < self.input.len) {
                    self.input[self.input_len] = char;
                    self.input_len += 1;
                }
            }
        },
    }
}

fn charFromSym(sym: KeySym, shift: bool) ?u8 {
    const value = @intFromEnum(sym);
    // every non-printable key (control, modifier, navigation, function, numpad) sits above '~'
    if (value < ' ' or value > '~') return null;
    if (value >= 'A' and value <= 'Z') return if (shift) value else value + ('a' - 'A');
    // no keyboard-layout table, so shifted digits/punctuation type unshifted
    return value;
}
