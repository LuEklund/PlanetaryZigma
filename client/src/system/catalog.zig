//! Every player-facing asset as plain records for the Obsidian asset board
//! (`tools/asset_board.py`). One `key: value` per line, records separated by a blank line.
const std = @import("std");
const shared = @import("shared");
const entity = shared.entity;

pub fn write(writer: *std.Io.Writer) !void {
    for (std.enums.values(shared.Survivor.Kind)) |kind| try survivor(writer, kind);
    for (std.enums.values(entity.EnemyKind)) |kind| try monster(writer, kind);
    for (std.enums.values(shared.Elite.Kind)) |kind| if (kind != .none) try elite(writer, kind);
    for (std.enums.values(shared.Item.Kind)) |kind| try item(writer, kind);
    for (interactables) |row| try interactable(writer, row);
    for (std.enums.values(shared.Biome.Kind)) |kind| try biome(writer, kind);
    for (sounds) |row| try sound(writer, row);
}

const Sound = struct { slot: []const u8, file: []const u8, category: []const u8, when: []const u8 };

/// Every sound the game wants; `tools/asset_board.py` marks the ones whose file is missing.
const sounds = [_]Sound{
    .{ .slot = "shoot", .file = "laser-gun.mp3", .category = "sfx", .when = "Survivor and monster shots (shoot, scatter, cube)." },
    .{ .slot = "melee", .file = "punch.mp3", .category = "sfx", .when = "Melee hits (punch, cone, slam)." },
    .{ .slot = "ui-click", .file = "button-click.mp3", .category = "sfx", .when = "Menu button press (unused since the dvui port)." },
    .{ .slot = "ui-hover", .file = "button-hover.mp3", .category = "sfx", .when = "Menu button hover (unused since the dvui port)." },
    .{ .slot = "jump", .file = "jump.mp3", .category = "sfx", .when = "Player jump and feather air jump." },
    .{ .slot = "hurt", .file = "hurt.mp3", .category = "sfx", .when = "Player takes damage." },
    .{ .slot = "low-health", .file = "low-health.mp3", .category = "sfx", .when = "Loop while under 35% health (heartbeat)." },
    .{ .slot = "enemy-hit", .file = "enemy-hit.mp3", .category = "sfx", .when = "A monster takes damage (short tick)." },
    .{ .slot = "enemy-death", .file = "enemy-death.mp3", .category = "sfx", .when = "A monster dies." },
    .{ .slot = "enemy-spawn", .file = "enemy-spawn.mp3", .category = "sfx", .when = "Monster spawn puff." },
    .{ .slot = "elite-spawn", .file = "elite-spawn.mp3", .category = "sfx", .when = "An elite appears." },
    .{ .slot = "explosion", .file = "explosion.mp3", .category = "sfx", .when = "Rockets, grenades, bombers, gasoline." },
    .{ .slot = "lightning", .file = "lightning.mp3", .category = "sfx", .when = "Chain lightning proc." },
    .{ .slot = "heal", .file = "heal.mp3", .category = "sfx", .when = "Healing pulses and heal projectiles." },
    .{ .slot = "chest-open", .file = "chest-open.mp3", .category = "sfx", .when = "Chest, multishop, shrine of chance pays out." },
    .{ .slot = "item-pickup", .file = "item-pickup.mp3", .category = "sfx", .when = "Item picked up." },
    .{ .slot = "gold", .file = "gold.mp3", .category = "sfx", .when = "Gold gained (barrel, kill)." },
    .{ .slot = "shrine", .file = "shrine.mp3", .category = "sfx", .when = "Shrine used (combat, mountain, chance)." },
    .{ .slot = "shrine-fail", .file = "shrine-fail.mp3", .category = "sfx", .when = "Shrine of chance gives nothing." },
    .{ .slot = "printer", .file = "printer.mp3", .category = "sfx", .when = "3D printer trade." },
    .{ .slot = "drone", .file = "drone.mp3", .category = "sfx", .when = "Drone repaired and drone shots." },
    .{ .slot = "teleporter-activate", .file = "teleporter-activate.mp3", .category = "sfx", .when = "Teleporter event starts (boss arrives)." },
    .{ .slot = "teleporter-charged", .file = "teleporter-charged.mp3", .category = "sfx", .when = "Teleporter fully charged." },
    .{ .slot = "stage-travel", .file = "stage-travel.mp3", .category = "sfx", .when = "Leaving a planet / arriving at the next." },
    .{ .slot = "ping", .file = "ping.mp3", .category = "sfx", .when = "Middle-mouse ping." },
    .{ .slot = "family-event", .file = "family-event.mp3", .category = "sfx", .when = "Family event announcement." },
    .{ .slot = "menu", .file = "music-menu.mp3", .category = "music", .when = "Main menu." },
    .{ .slot = "ship", .file = "music-ship.mp3", .category = "music", .when = "The ship / character select lobby." },
    .{ .slot = "coral", .file = "music-coral.mp3", .category = "music", .when = "Stage music, Coral Shelf." },
    .{ .slot = "verdant", .file = "music-verdant.mp3", .category = "music", .when = "Stage music, Verdant Hills." },
    .{ .slot = "frost", .file = "music-frost.mp3", .category = "music", .when = "Stage music, Frost Spires." },
    .{ .slot = "dust", .file = "music-dust.mp3", .category = "music", .when = "Stage music, Dust Basin." },
    .{ .slot = "boss", .file = "music-boss.mp3", .category = "music", .when = "Teleporter event / boss fight." },
    .{ .slot = "loop", .file = "music-loop.mp3", .category = "music", .when = "Looped (night) stages, after stage 5." },
    .{ .slot = "wipe", .file = "music-wipe.mp3", .category = "music", .when = "Everyone died (short sting)." },
};

fn sound(writer: *std.Io.Writer, row: Sound) !void {
    try writer.print("id: {s}-{s}\nname: {s}\ncategory: {s}\nthumb: none\n", .{ row.category, row.slot, row.file, row.category });
    try field(writer, "description", row.when);
    try writer.print("file: sounds/{s}\n\n", .{row.file});
}

const Interactable = struct { kind: entity.Kind, name: []const u8, description: []const u8 };

const interactables = [_]Interactable{
    .{ .kind = .teleporter, .name = "Teleporter", .description = "Activate to start the boss event; charge it by standing in its zone, then use it again to leave the planet." },
    .{ .kind = .lootbox, .name = "Chest", .description = "Pay gold for a random item (common 75%, uncommon 19%, ...)." },
    .{ .kind = .barrel, .name = "Barrel", .description = "Free; a little gold." },
    .{ .kind = .multishop, .name = "Multishop terminal", .description = "Three in a row, each shows an item; buying one closes the others." },
    .{ .kind = .printer, .name = "3D Printer", .description = "Trades one random item of the same tier for its item." },
    .{ .kind = .drone_broken, .name = "Broken Drone", .description = "Pay to repair; becomes an ally drone." },
    .{ .kind = .drone, .name = "Drone", .description = "Ally: hovers beside its owner and shoots the nearest monster it can see." },
    .{ .kind = .shrine_combat, .name = "Shrine of Combat", .description = "Free; summons a wave of monsters right away." },
    .{ .kind = .shrine_mountain, .name = "Shrine of the Mountain", .description = "Free; the teleporter boss gets twice the budget and drops twice the items." },
    .{ .kind = .shrine_chance, .name = "Shrine of Chance", .description = "Pay gold; 45% nothing (price rises), otherwise an item." },
};

fn field(writer: *std.Io.Writer, key: []const u8, value: []const u8) !void {
    try writer.print("{s}: ", .{key});
    for (value) |char| try writer.writeByte(if (char == '\n') ' ' else char);
    try writer.writeByte('\n');
}

fn stats(writer: *std.Io.Writer, base: *const std.EnumArray(shared.Item.Stat, f32)) !void {
    try writer.writeAll("stats: ");
    var first = true;
    for (std.enums.values(shared.Item.Stat)) |stat| {
        const value = base.get(stat);
        if (value == 0) continue;
        try writer.print("{s}{t} {d}", .{ if (first) "" else ", ", stat, value });
        first = false;
    }
    try writer.writeByte('\n');
}

fn abilities(writer: *std.Io.Writer, skills: *const std.EnumArray(entity.Action, ?entity.AssignedSkill)) !void {
    try writer.writeAll("abilities: ");
    var first = true;
    for (std.enums.values(entity.Action)) |action| {
        const assigned = skills.get(action) orelse continue;
        const info = shared.skill_info.get(assigned.skill);
        try writer.print("{s}{t}: {s} ({s})", .{ if (first) "" else " · ", action, info.name, info.description });
        first = false;
    }
    try writer.writeByte('\n');
}

fn survivor(writer: *std.Io.Writer, kind: shared.Survivor.Kind) !void {
    const row = shared.Survivor.get(kind);
    try writer.print("id: survivor-{t}\n", .{kind});
    try field(writer, "name", row.name);
    try field(writer, "category", "survivor");
    try field(writer, "thumb", "zoo:player");
    try field(writer, "description", row.description);
    try stats(writer, &row.base_stats);
    try abilities(writer, &row.abilities);
    try writer.writeByte('\n');
}

fn monster(writer: *std.Io.Writer, kind: entity.EnemyKind) !void {
    const spec = entity.Kind.spec(.{ .enemy = kind });
    try writer.print("id: monster-{t}\nname: {t}\ncategory: monster\nthumb: zoo:{t}\n", .{ kind, kind, kind });
    try writer.print("description: {t} monster, behavior {t}, card cost {d}, from stage {d}\n", .{
        spec.category,
        spec.behavior,
        spec.currency,
        spec.min_stage + 1,
    });
    try stats(writer, &spec.base_stats);
    try abilities(writer, &spec.skills);
    const model = spec.model orelse return writer.writeAll("needs: model\n\n");
    if (model.path.len == 0) try writer.writeAll("needs: model\n");
    try writer.writeByte('\n');
}

fn elite(writer: *std.Io.Writer, kind: shared.Elite.Kind) !void {
    const row = shared.Elite.get(kind);
    try writer.print("id: elite-{t}\n", .{kind});
    try field(writer, "name", row.name);
    try writer.print("category: elite\nthumb: none\n", .{});
    try writer.print("description: tier {d} elite: x{d} health, x{d} damage, x{d} cost; grants", .{
        row.tier,
        row.health_multiplier,
        row.damage_multiplier,
        row.cost_multiplier,
    });
    for (row.granted_items) |grant| try writer.print(" {d}x {t}", .{ grant.count, grant.item });
    try writer.writeAll("\n\n");
}

fn item(writer: *std.Io.Writer, kind: shared.Item.Kind) !void {
    const row = shared.Item.get(kind);
    try writer.print("id: item-{t}\nname: {t}\n", .{ kind, kind });
    try writer.print("category: {s}\n", .{if (row.is_equipment) "equipment" else "item"});
    try writer.print("thumb: icon:{s}\n", .{shared.Item.icon_paths[@intFromEnum(kind)]});
    try field(writer, "description", row.description);
    try writer.print("stats: tier {t}\n", .{row.tier});
    try writer.print("needs: model {s}, icon {s}\n\n", .{ shared.Item.model_paths[@intFromEnum(kind)], shared.Item.icon_paths[@intFromEnum(kind)] });
}

fn interactable(writer: *std.Io.Writer, row: Interactable) !void {
    try writer.print("id: interactable-{t}\n", .{row.kind});
    try field(writer, "name", row.name);
    try writer.print("category: interactable\nthumb: zoo:{t}\n", .{row.kind});
    try field(writer, "description", row.description);
    const spec = row.kind.spec();
    if (spec.currency != 0) try writer.print("stats: base price {d}\n", .{spec.currency});
    const model = spec.model orelse return writer.writeAll("needs: model\n\n");
    if (model.path.len == 0 or std.mem.eql(u8, model.path, "objects/pillar.glb") and row.kind != .teleporter)
        try writer.writeAll("needs: model (placeholder now)\n");
    try writer.writeByte('\n');
}

fn biome(writer: *std.Io.Writer, kind: shared.Biome.Kind) !void {
    const row = shared.Biome.forRadius(shared.Biome.radiusFor(kind, 1000));
    try writer.print("id: biome-{t}\n", .{kind});
    try field(writer, "name", row.name);
    try writer.print("category: biome\nthumb: biome:{d}\n", .{shared.Biome.radiusFor(kind, 124)});
    try writer.print("description: props trees {d} rocks {d} grass {d} per flat cell; water {s}\n\n", .{
        row.props.trees,
        row.props.rocks,
        row.props.grass,
        if (row.water != null) "yes" else "no",
    });
}
