const Audio = @This();

const std = @import("std");
const ma = @import("miniaudio");

const Handle = u32;
pub const Kind = enum {
    button_hover,
    button_click,

    shoot,
    spread_shot,
    dash,
    use_equipment,
    shoot_cube,
    melee,
    arc_jump,
    plant,

    idle,
    walk,
    death,
    stun,
};

asset_root: []const u8,
engine: ma.ma_engine,
sounds: [128]ma.ma_sound,
map_sounds: std.EnumArray(Kind, u32),
next_sound: u32,

pub fn init(self: *Audio, gpa: std.mem.Allocator, asset_root: []const u8) !void {
    if (ma.ma_engine_init(null, &self.engine) != ma.MA_SUCCESS) return error.Miniaudio;
    self.next_sound = 0;
    self.asset_root = try std.fmt.allocPrint(gpa, "{s}/sounds/", .{asset_root});

    var sound_path_buffer: [128]u8 = undefined;
    self.map_sounds.set(.button_hover, try self.addSound(try std.fmt.bufPrintZ(&sound_path_buffer, "{s}/sounds/button-hover.mp3", .{asset_root})));
    self.map_sounds.set(.button_click, try self.addSound(try std.fmt.bufPrintZ(&sound_path_buffer, "{s}/sounds/button-click.mp3", .{asset_root})));
    self.map_sounds.set(.shoot_cube, try self.addSound(try std.fmt.bufPrintZ(&sound_path_buffer, "{s}/sounds/laser-gun.mp3", .{asset_root})));
    try self.addMapSpound(.melee, "punch.mp3");
}

pub fn deinit(self: *Audio) void {
    for (self.sounds[0..self.next_sound]) |*sound| ma.ma_sound_uninit(sound);
    ma.ma_engine_uninit(&self.engine);
}

fn addMapSpound(self: *Audio, kind: Kind, file: []const u8) !void {
    var sound_path_buffer: [128]u8 = undefined;
    self.map_sounds.set(kind, try self.addSound(try std.fmt.bufPrintZ(&sound_path_buffer, "{s}{s}", .{ self.asset_root, file })));
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

pub fn playSoundKind(self: *Audio, kind: Kind) !void {
    const handle = self.map_sounds.get(kind);
    if (ma.ma_sound_start(
        &self.sounds[handle],
    ) != ma.MA_SUCCESS) return error.MiniaudioPlaySoundKind;
}

pub fn playSound(self: *Audio, handle: Handle) !void {
    if (ma.ma_sound_start(
        &self.sounds[handle],
    ) != ma.MA_SUCCESS) return error.MiniaudioPlaySound;
}
