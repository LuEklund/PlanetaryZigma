const std = @import("std");
const Assets = @import("../Watcher.zig");
const Bitmap = @import("../types/Bitmap.zig");

const channels: u32 = 4;

/// Pixels for one texture. `faces` are windows into `block`, which is why freeing has to go
/// through `deinit` — releasing a face releases part of a block, not the block.
pub const Decoded = struct {
    block: []u8,
    faces: [][]const u8,
    width: u32,
    height: u32,

    pub fn deinit(self: *Decoded, gpa: std.mem.Allocator) void {
        gpa.free(self.faces);
        gpa.free(self.block);
        self.* = undefined;
    }
};

/// `cubemap` says to read the file as a 4x3 cross and hand back six faces. Which slot that
/// is, is the caller's business.
pub fn decode(gpa: std.mem.Allocator, watcher: *Assets, io: std.Io, entry: u32, cubemap: bool) !Decoded {
    const file = try watcher.open(io, entry);
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const len: usize = @intCast((try file.stat(io)).size);
    const encoded = try gpa.alloc(u8, len);
    defer gpa.free(encoded);
    try reader.interface.readSliceAll(encoded);

    var decoded: Bitmap = .{};
    var tasks: [1]Bitmap.Task = .{.{ .result = &decoded, .bytes = encoded }};
    try Bitmap.decodeAll(gpa, &tasks);
    defer decoded.deinit();
    if (decoded.err) |err| return err;
    try if (decoded.pixels == null) error.LoadingStbi;

    return if (cubemap) splitCross(gpa, decoded) else wholeImage(gpa, decoded);
}

fn wholeImage(gpa: std.mem.Allocator, decoded: Bitmap) !Decoded {
    const width: u32 = @intCast(decoded.width);
    const height: u32 = @intCast(decoded.height);
    const bytes = try gpa.dupe(u8, decoded.pixels[0 .. width * height * channels]);
    errdefer gpa.free(bytes);
    const faces = try gpa.alloc([]const u8, 1);
    faces[0] = bytes;
    return .{ .block = bytes, .faces = faces, .width = width, .height = height };
}

/// 4x3 cross layout -> six square faces in Vulkan cubemap order, all windows into one block.
fn splitCross(gpa: std.mem.Allocator, decoded: Bitmap) !Decoded {
    const width: u32 = @intCast(decoded.width);
    const face_size: u32 = @divTrunc(width, 4);
    const face_bytes = face_size * face_size * channels;
    const row_bytes = face_size * channels;

    const bytes = try gpa.alloc(u8, face_bytes * 6);
    errdefer gpa.free(bytes);
    const faces = try gpa.alloc([]const u8, 6);
    errdefer gpa.free(faces);

    for (0..6) |face| {
        var x_start: u32, var y_start: u32 = switch (face) {
            0 => .{ 2, 1 },
            1 => .{ 0, 1 },
            2 => .{ 1, 0 },
            3 => .{ 1, 2 },
            4 => .{ 1, 1 },
            5 => .{ 3, 1 },
            else => unreachable,
        };
        x_start *= face_size;
        y_start *= face_size;

        const target = bytes[face * face_bytes ..][0..face_bytes];
        for (0..face_size) |y| {
            const dst = y * row_bytes;
            const src = ((y_start + y) * width + x_start) * channels;
            @memcpy(target[dst..][0..row_bytes], decoded.pixels[src..][0..row_bytes]);
        }
        faces[face] = target;
    }
    return .{ .block = bytes, .faces = faces, .width = face_size, .height = face_size };
}
