const std = @import("std");

pub const Setting = enum(u8) {
    drizzle,
    rainstorm,
    monsoon,

    pub fn value(setting: Setting) f32 {
        return switch (setting) {
            .drizzle => 1,
            .rainstorm => 2,
            .monsoon => 3,
        };
    }

    pub fn description(setting: Setting) []const u8 {
        return switch (setting) {
            .drizzle => "For new players. Difficulty rises slowly.",
            .rainstorm => "The way the game is meant to be played.",
            .monsoon => "For veterans. Difficulty rises fast.",
        };
    }

    pub fn label(setting: Setting) []const u8 {
        return switch (setting) {
            .drizzle => "Drizzle",
            .rainstorm => "Rainstorm",
            .monsoon => "Monsoon",
        };
    }
};

pub const per_player_factor: f32 = 0.3;
pub const time_factor_per_minute: f32 = 0.0506;
pub const stage_growth: f32 = 1.15;
pub const coefficient_per_level: f32 = 0.33;
pub const health_per_level: f32 = 0.3;
pub const damage_per_level: f32 = 0.2;
pub const chest_cost_exponent: f32 = 1.25;
pub const max_level: f32 = 99;

pub fn playerFactor(players: usize) f32 {
    const count: f32 = @floatFromInt(@max(players, 1));
    return 1 + per_player_factor * (count - 1);
}

pub fn coefficient(setting: Setting, run_seconds: f32, players: usize, stages_completed: u32) f32 {
    const count: f32 = @floatFromInt(@max(players, 1));
    const time_factor = time_factor_per_minute * setting.value() * std.math.pow(f32, count, 0.2);
    const stage_factor = std.math.pow(f32, stage_growth, @floatFromInt(stages_completed));
    return (playerFactor(players) + run_seconds / 60 * time_factor) * stage_factor;
}

pub fn level(difficulty_coefficient: f32, players: usize) f32 {
    return std.math.clamp(@floor(1 + (difficulty_coefficient - playerFactor(players)) / coefficient_per_level), 1, max_level);
}

pub fn healthMultiplier(monster_level: f32) f32 {
    return 1 + health_per_level * (monster_level - 1);
}

pub fn damageMultiplier(monster_level: f32) f32 {
    return 1 + damage_per_level * (monster_level - 1);
}

pub fn chestCost(base_cost: u32, difficulty_coefficient: f32) u32 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(base_cost)) * std.math.pow(f32, difficulty_coefficient, chest_cost_exponent)));
}

pub fn killReward(base_reward: u32, difficulty_coefficient: f32) u32 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(base_reward)) * difficulty_coefficient));
}

pub fn directorCreditScale(difficulty_coefficient: f32, players: usize) f32 {
    const count: f32 = @floatFromInt(@max(players, 1));
    return (1 + 0.4 * difficulty_coefficient) / 1.4 * (count + 1) / 2;
}
