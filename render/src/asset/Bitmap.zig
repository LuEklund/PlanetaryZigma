const Bitmap = @This();

const std = @import("std");
const stb_image = @import("stb_image");

pixels: [*c]stb_image.stbi_uc = null,
width: i32 = 0,
height: i32 = 0,
nr_channel: i32 = 0,
err: ?Error = null,

pub const Error = error{
    DataNotSupported,
    FailedToLoadGLTFImage,
    LoadingStbi,
    MissingBufferViews,
};

pub const Task = struct {
    bytes: ?[]const u8 = null,
    uri: ?[:0]const u8 = null,
    result: *Bitmap,
};

pub fn deinit(self: *Bitmap) void {
    if (self.pixels != null) stb_image.stbi_image_free(self.pixels);
    self.* = .{};
}

pub fn decodeAll(gpa: std.mem.Allocator, tasks: []Task) !void {
    if (tasks.len == 0) return;

    const cpu_count = std.Thread.getCpuCount() catch 1;
    const worker_count = @min(tasks.len, @max(@as(usize, 1), cpu_count));
    if (worker_count == 1) {
        decodeWorker(tasks, 0, 1);
        return;
    }

    var threads = try gpa.alloc(std.Thread, worker_count);
    defer gpa.free(threads);

    var spawned: usize = 0;
    errdefer {
        for (threads[0..spawned]) |thread| thread.join();
    }

    while (spawned < worker_count) : (spawned += 1) {
        threads[spawned] = try std.Thread.spawn(.{}, decodeWorker, .{ tasks, spawned, worker_count });
    }
    for (threads) |thread| thread.join();
}

fn decodeWorker(tasks: []Task, worker_index: usize, worker_count: usize) void {
    var image_index = worker_index;
    while (image_index < tasks.len) : (image_index += worker_count) {
        decodeTask(&tasks[image_index]);
    }
}

fn decodeTask(task: *Task) void {
    var width: i32 = 0;
    var height: i32 = 0;
    var nr_channel: i32 = 0;

    if (task.uri) |uri| {
        task.result.pixels = stb_image.stbi_load(uri, &width, &height, &nr_channel, 4);
    } else if (task.bytes) |bytes| {
        task.result.pixels = stb_image.stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &width, &height, &nr_channel, 4);
    } else {
        task.result.err = error.FailedToLoadGLTFImage;
        return;
    }

    if (task.result.pixels == null) {
        task.result.err = error.LoadingStbi;
        return;
    }

    task.result.width = width;
    task.result.height = height;
    task.result.nr_channel = nr_channel;
}
