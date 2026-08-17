const Audio = @This();

const std = @import("std");
const ma = @import("miniaudio");

const sample_rate: u32 = 48000;
const channel_count: u32 = 2;

pub const Sound = enum(u32) {
    none = std.math.maxInt(u32),
    _,
};

const Clip = struct { samples: []f32, max_count: u8 };

const Voice = struct {
    sound: Sound,
    cursor: u32,
    alive: bool,
};

sounds: [128]Clip,
root: []const u8,

device: ma.ma_device,
ring: ma.ma_pcm_rb,
next_sound: u32,
voices: [32]Voice,

pub fn init(self: *Audio, root: []const u8) !void {
    self.next_sound = 0;
    self.root = root;
    for (&self.voices) |*voice| voice.alive = false;
    if (ma.ma_pcm_rb_init(ma.ma_format_f32, channel_count, 2048, null, null, &self.ring) != ma.MA_SUCCESS) return error.MiniaudioRing;
    var config: ma.ma_device_config = ma.ma_device_config_init(ma.ma_device_type_playback);
    config.playback.format = ma.ma_format_f32;
    config.playback.channels = channel_count;
    config.sampleRate = sample_rate;
    config.dataCallback = drain;
    config.pUserData = &self.ring;
    if (ma.ma_device_init(null, &config, &self.device) != ma.MA_SUCCESS) return error.MiniaudioDevice;
    if (ma.ma_device_start(&self.device) != ma.MA_SUCCESS) return error.MiniaudioStart;
}

pub fn deinit(self: *Audio) void {
    ma.ma_device_uninit(&self.device);
    ma.ma_pcm_rb_uninit(&self.ring);
    for (self.sounds[0..self.next_sound]) |sound| ma.ma_free(sound.samples.ptr, null);
}

pub fn update(self: *Audio) void {
    var frames_free: u32 = ma.ma_pcm_rb_available_write(&self.ring);
    while (frames_free > 0) {
        var chunk: u32 = frames_free;
        var dst_raw: ?*anyopaque = undefined;
        if (ma.ma_pcm_rb_acquire_write(&self.ring, &chunk, &dst_raw) != ma.MA_SUCCESS or chunk == 0) return;
        const dst: []f32 = @as([*]f32, @ptrCast(@alignCast(dst_raw.?)))[0 .. chunk * channel_count];
        @memset(dst, 0);
        for (&self.voices) |*voice| {
            if (!voice.alive) continue;
            const sound: []f32 = self.sounds[@intFromEnum(voice.sound)].samples;
            var i: u32 = 0;
            while (i < dst.len and voice.cursor < sound.len) : (i += 1) {
                dst[i] += sound[voice.cursor];
                voice.cursor += 1;
            }
            if (voice.cursor >= sound.len) voice.alive = false;
        }
        _ = ma.ma_pcm_rb_commit_write(&self.ring, chunk);
        frames_free -= chunk;
    }
}

pub fn play(self: *Audio, sound: Sound) void {
    if (sound == .none) return;

    var free_slot: ?*Voice = null;
    var oldest_voice: ?*Voice = null;
    var same_sound_count: u32 = 0;
    const clip = self.sounds[@intFromEnum(sound)];

    //replace oldest sound if max_count is reached
    for (&self.voices) |*voice| {
        if (!voice.alive) {
            if (free_slot == null) free_slot = voice;
            continue;
        }
        if (voice.sound != sound) continue;
        same_sound_count += 1;
        if (oldest_voice == null or voice.cursor > oldest_voice.?.cursor) oldest_voice = voice;
    }
    if (same_sound_count >= clip.max_count) {
        oldest_voice.?.* = .{ .sound = sound, .cursor = 0, .alive = true };
    } else if (free_slot) |slot| {
        slot.* = .{ .sound = sound, .cursor = 0, .alive = true };
    }
}

///Assumes Assets dir of Project
pub fn load(
    self: *Audio,
    file: [:0]const u8,
    options: struct { max_count: u8 = 5 },
) !Sound {
    var path_buffer: [256]u8 = undefined;
    const path: [:0]u8 = try std.fmt.bufPrintZ(&path_buffer, "{s}/sounds/{s}", .{ self.root, file });

    var decoder_config: ma.ma_decoder_config = ma.ma_decoder_config_init(ma.ma_format_f32, channel_count, sample_rate);
    var frame_count: u64 = undefined;
    var pcm: ?*anyopaque = undefined;
    if (ma.ma_decode_file(path.ptr, &decoder_config, &frame_count, &pcm) != ma.MA_SUCCESS) return error.MiniaudioDecode;

    self.sounds[self.next_sound] = .{
        .max_count = options.max_count,
        .samples = @as([*]f32, @ptrCast(@alignCast(pcm.?)))[0 .. frame_count * channel_count],
    };

    self.next_sound += 1;
    return @enumFromInt(self.next_sound - 1);
}

//NOTE: Because of hellshit callbacks this function wont be updated on hotreload.
fn drain(device: [*c]ma.ma_device, out: ?*anyopaque, _: ?*const anyopaque, frame_count: u32) callconv(.c) void {
    const ring: *ma.ma_pcm_rb = @ptrCast(@alignCast(device.*.pUserData.?));
    var dst: [*]f32 = @ptrCast(@alignCast(out.?));
    var frames_left: u32 = frame_count;
    while (frames_left > 0) {
        var chunk: u32 = frames_left;
        var src: ?*anyopaque = undefined;
        if (ma.ma_pcm_rb_acquire_read(ring, &chunk, &src) != ma.MA_SUCCESS or chunk == 0) break;
        @memcpy(dst[0 .. chunk * channel_count], @as([*]f32, @ptrCast(@alignCast(src.?)))[0 .. chunk * channel_count]);
        _ = ma.ma_pcm_rb_commit_read(ring, chunk);
        dst += chunk * channel_count;
        frames_left -= chunk;
    }
}
