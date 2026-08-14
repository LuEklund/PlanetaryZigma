const Discord = @This();

const std = @import("std");
const System = @import("../System.zig");

const handshake: []const u8 = "{\"v\":1,\"client_id\":\"1537156190709219378\"}";
pub const State = struct {
    scene: System.Scene,
};

socket: ?std.Io.net.Stream,
last: ?State,
next_send_time: f32,
dir: []const u8,
nonce: u32,

pub fn update(self: *Discord, io: std.Io, state: State, elapsed_time: f32) void {
    if (elapsed_time < self.next_send_time) return;
    if (self.socket == null) {
        self.connect(io);
        if (self.socket == null) return;
    }
    if (self.last) |last_state| if (std.meta.eql(state, last_state)) return;
    self.last = state;
    self.next_send_time = elapsed_time + 15;

    const details: []const u8 = switch (state.scene) {
        .menu => "In Menu",
        .game => "On a Planet",
        .particle_lab => "In THE Secret lab",
    };
    self.nonce += 1;
    var nonce_buffer: [12]u8 = undefined;
    var json_buffer: [512]u8 = undefined;
    var json_writer = std.Io.Writer.fixed(&json_buffer);
    std.json.Stringify.value(.{
        .cmd = "SET_ACTIVITY",
        .nonce = std.fmt.bufPrint(&nonce_buffer, "{d}", .{self.nonce}) catch return,
        .args = .{
            .pid = std.os.linux.getpid(),
            .activity = .{
                .details = details,
            },
        },
    }, .{}, &json_writer) catch return;
    self.send(io, 1, json_writer.buffered());
}

fn connect(self: *Discord, io: std.Io) void {
    var path_buffer: [256]u8 = undefined;
    for (0..10) |index| {
        const path = std.fmt.bufPrint(&path_buffer, "{s}/discord-ipc-{d}", .{ self.dir, index }) catch return;
        const address = std.Io.net.UnixAddress.init(path) catch return;
        self.socket = address.connect(io) catch continue;
        self.send(io, 0, handshake);
        return;
    }
}

fn send(self: *Discord, io: std.Io, opcode: u32, json: []const u8) void {
    const socket = self.socket orelse return;
    var frame_buffer: [1024]u8 = undefined;
    std.mem.writeInt(u32, frame_buffer[0..4], opcode, .little);
    std.mem.writeInt(u32, frame_buffer[4..8], @intCast(json.len), .little);
    @memcpy(frame_buffer[8..][0..json.len], json);
    var write_buffer: [1024]u8 = undefined;
    var writer = socket.writer(io, &write_buffer);
    writer.interface.writeAll(frame_buffer[0 .. 8 + json.len]) catch {
        socket.close(io);
        self.socket = null;
        return;
    };
    writer.interface.flush() catch {};
}
