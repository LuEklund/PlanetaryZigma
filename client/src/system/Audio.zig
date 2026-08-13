const Audio = @This();

const std = @import("std");
const ma = @import("miniaudio");

const Handle = u32;

engine: ma.ma_engine,
sounds: [128]ma.ma_sound,
next_sound: u32,

pub fn init(self: *Audio) !void {
    if (ma.ma_engine_init(null, &self.engine) != ma.MA_SUCCESS) return error.Miniaudio;
    self.next_sound = 0;
}

pub fn deinit(self: *Audio) void {
    for (self.sounds[0..self.next_sound]) |*sound| ma.ma_sound_uninit(sound);
    ma.ma_engine_uninit(&self.engine);
}

pub fn addSound(self: *Audio, path: [:0]const u8) !Handle {
    const handle = self.next_sound;
    if (ma.ma_sound_init_from_file(
        &self.engine,
        path.ptr,
        ma.MA_SOUND_FLAG_DECODE,
        null,
        null,
        &self.sounds[self.next_sound],
    ) != ma.MA_SUCCESS) return error.MiniaudioAddSound;
    self.next_sound += 1;
    return handle;
}

pub fn playSound(self: *Audio, handle: Handle) !void {
    if (ma.ma_sound_start(
        &self.sounds[handle],
    ) != ma.MA_SUCCESS) return error.MiniaudioPlaySound;
}
