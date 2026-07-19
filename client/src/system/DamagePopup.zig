const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;

const DamagePopup = @This();

pub const lifetime: f32 = 0.8;

position: nz.Vec3(f32),
amount: f32,
color: [3]f32,
age: f32,

pub fn spawn(list: *std.ArrayList(DamagePopup), random: std.Random, position: nz.Vec3(f32), amount: f32, color: [3]f32) void {
    if (list.items.len >= list.capacity) _ = list.orderedRemove(0);
    const jitter = nz.vec.scale(nz.vec.randomUnitVector(nz.Vec3(f32), random), 0.35);
    list.appendAssumeCapacity(.{
        .position = position + jitter,
        .amount = amount,
        .color = color,
        .age = 0,
    });
}

pub fn update(list: *std.ArrayList(DamagePopup), delta_time: f32) void {
    var index: usize = 0;
    while (index < list.items.len) {
        const popup = &list.items[index];
        popup.age += delta_time;
        if (popup.age >= lifetime) {
            _ = list.swapRemove(index);
            continue;
        }
        index += 1;
    }
}
