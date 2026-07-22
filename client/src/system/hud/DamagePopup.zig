const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;

const DamagePopup = @This();

pub const lifetime: f32 = 0.8;

position: nz.Vec3(f32),
amount: f32,
color: [3]f32,
age: f32,

pub const max_popups = 128;

pub const List = struct {
    popups: [max_popups]DamagePopup = undefined,
    count: usize = 0,

    pub fn items(self: *const List) []const DamagePopup {
        return self.popups[0..self.count];
    }

    pub fn spawn(self: *List, random: std.Random, position: nz.Vec3(f32), amount: f32, color: [3]f32) void {
        if (self.count >= max_popups) {
            std.mem.copyForwards(DamagePopup, self.popups[0 .. max_popups - 1], self.popups[1..max_popups]);
            self.count = max_popups - 1;
        }
        const jitter = nz.vec.scale(nz.vec.randomUnitVector(nz.Vec3(f32), random), 0.35);
        self.popups[self.count] = .{
            .position = position + jitter,
            .amount = amount,
            .color = color,
            .age = 0,
        };
        self.count += 1;
    }

    pub fn update(self: *List, delta_time: f32) void {
        var index: usize = 0;
        while (index < self.count) {
            const popup = &self.popups[index];
            popup.age += delta_time;
            if (popup.age >= lifetime) {
                self.count -= 1;
                self.popups[index] = self.popups[self.count];
                continue;
            }
            index += 1;
        }
    }
};
