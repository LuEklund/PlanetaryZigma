const Audio = @This();

const std = @import("std");
const miniaudio = @import("miniaudio");

const Engine = miniaudio.ma_engine;
const Sound = miniaudio.ma_sound;
const Handle = u32;

engine: Engine,
sounds: [128]Sound,
next_sound: u32,

pub fn init(self: *Audio) !void {
    if (miniaudio.ma_engine_init(null, &self.engine) != miniaudio.MA_SUCCESS) return error.MiniaudioFailed;
    self.next_sound = 0;
}

pub fn deinit(self: *Audio) void {
    for (self.sounds[0..self.next_sound]) |*sound| miniaudio.ma_sound_uninit(sound);
    miniaudio.ma_engine_uninit(&self.engine);
}

pub fn addSound(self: *Audio, path: [:0]const u8) !Handle {
    const handle = self.next_sound;
    if (miniaudio.ma_sound_init_from_file(
        &self.engine,
        path.ptr,
        miniaudio.MA_SOUND_FLAG_DECODE,
        null,
        null,
        &self.sounds[self.next_sound],
    ) != miniaudio.MA_SUCCESS) return error.MiniaudioFailedAddSound;
    self.next_sound += 1;
    return handle;
}

pub fn playSound(self: *Audio, handle: Handle) !void {
    if (miniaudio.ma_sound_start(
        &self.sounds[handle],
    ) != miniaudio.MA_SUCCESS) return error.MiniaudioFailedPlaySound;
}
