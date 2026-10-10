const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const World = @import("../World.zig");
const Entity = World.Entity;
const combat = @import("combat.zig");
const items = @import("items.zig");
const PlayerController = @import("PlayerController.zig");

pub const prefix = '/';

const Args = std.mem.TokenIterator(u8, .scalar);

const Command = struct {
    name: []const u8,
    usage: []const u8,
    run: *const fn (world: *World, player: *Entity, args: *Args, reply: []u8) []const u8,
};

const table = [_]Command{
    .{ .name = "help", .usage = "/help", .run = help },
    .{ .name = "spawn", .usage = "/spawn <enemy> [count] [elite]", .run = spawn },
    .{ .name = "give", .usage = "/give <item> [count]", .run = give },
    .{ .name = "money", .usage = "/money <amount>", .run = money },
    .{ .name = "heal", .usage = "/heal", .run = heal },
    .{ .name = "god", .usage = "/god", .run = god },
    .{ .name = "kill", .usage = "/kill me|all", .run = kill },
    .{ .name = "stage", .usage = "/stage", .run = stage },
    .{ .name = "start", .usage = "/start", .run = start },
    .{ .name = "tp", .usage = "/tp teleporter", .run = teleport },
    .{ .name = "time", .usage = "/time <run seconds>", .run = time },
    .{ .name = "spawning", .usage = "/spawning", .run = spawning },
    .{ .name = "boss", .usage = "/boss (activate the teleporter)", .run = boss },
    .{ .name = "directors", .usage = "/directors", .run = directors },
};

/// Runs one chat line that starts with `prefix`. Returns the reply for the sender.
pub fn run(world: *World, player: *Entity, line: []const u8, reply: []u8) []const u8 {
    var args = std.mem.tokenizeScalar(u8, line[1..], ' ');
    const name = args.next() orelse return help(world, player, &args, reply);
    for (table) |command| {
        if (std.mem.eql(u8, command.name, name)) return command.run(world, player, &args, reply);
    }
    return print(reply, "unknown command /{s}, try /help", .{name});
}

fn print(reply: []u8, comptime format: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(reply, format, args) catch reply[0..0];
}

fn count(args: *Args, default: u32) u32 {
    const text = args.next() orelse return default;
    return std.fmt.parseInt(u32, text, 10) catch default;
}

fn help(_: *World, _: *Entity, _: *Args, reply: []u8) []const u8 {
    var writer: std.Io.Writer = .fixed(reply);
    for (table) |command| writer.print("{s}\n", .{command.usage}) catch break;
    return writer.buffered();
}

fn spawn(world: *World, player: *Entity, args: *Args, reply: []u8) []const u8 {
    const name = args.next() orelse return print(
        reply,
        "usage: /spawn <enemy> [count] [elite]",
        .{},
    );
    const enemy = std.meta.stringToEnum(shared.entity.EnemyKind, name) orelse
        return print(reply, "no enemy '{s}'", .{name});
    const amount = @min(count(args, 1), 50);
    const elite = if (args.next()) |text| std.meta.stringToEnum(
        shared.Elite.Kind,
        text,
    ) orelse .none else .none;
    const random = world.prng.random();
    var spawned: u32 = 0;
    for (0..amount) |_| {
        const surface = world.planet.surfacePointNear(player.transform.position, 6, 12, random);
        _ = world.spawn(.{
            .kind = .{ .enemy = enemy },
            .elite = elite,
            .transform = .{
                .position = surface + nz.vec.scale(shared.Planet.surfaceUp(surface), 2),
            },
            .last_used = .initDefault(0, .{ .primary = world.elapsed_time }),
        }) catch break;
        spawned += 1;
    }
    return print(reply, "spawned {d} {s}", .{ spawned, name });
}

fn give(world: *World, player: *Entity, args: *Args, reply: []u8) []const u8 {
    const name = args.next() orelse return print(reply, "usage: /give <item> [count]", .{});
    const item = std.meta.stringToEnum(shared.Item.Kind, name) orelse return print(
        reply,
        "no item '{s}'",
        .{name},
    );
    const amount: u8 = @intCast(@min(count(args, 1), 255));
    const total = items.giveItem(world, player, item, amount) orelse return print(
        reply,
        "could not give {s}",
        .{name},
    );
    return print(reply, "{s} x{d}", .{ name, total });
}

fn money(world: *World, player: *Entity, args: *Args, reply: []u8) []const u8 {
    player.currency += count(args, 1000);
    world.client_updates.appendAssumeCapacity(
        .{ .set_currency = .{ .id = player.id, .amount = player.currency } },
    );
    return print(reply, "money {d}", .{player.currency});
}

fn heal(world: *World, player: *Entity, _: *Args, reply: []u8) []const u8 {
    _ = combat.addHealth(world, player, player.max_health, null);
    return print(reply, "healed", .{});
}

fn god(_: *World, player: *Entity, _: *Args, reply: []u8) []const u8 {
    player.flags.invincible = !player.flags.invincible;
    return print(reply, "god {s}", .{if (player.flags.invincible) "on" else "off"});
}

fn kill(world: *World, player: *Entity, args: *Args, reply: []u8) []const u8 {
    const target = args.next() orelse "all";
    if (std.mem.eql(u8, target, "me")) {
        _ = combat.addHealth(world, player, -player.health, null);
        return print(reply, "killed you", .{});
    }
    var killed: u32 = 0;
    for (world.entities.values()) |*entity| {
        if (entity.kind != .enemy or entity.flags.is_dead) continue;
        _ = combat.addHealth(world, entity, -entity.max_health, null);
        killed += 1;
    }
    return print(reply, "killed {d} enemies", .{killed});
}

fn stage(world: *World, _: *Entity, _: *Args, reply: []u8) []const u8 {
    world.next_stage_requested = true;
    return print(reply, "next stage", .{});
}

fn start(world: *World, _: *Entity, _: *Args, reply: []u8) []const u8 {
    world.start_round_requested = true;
    return print(reply, "starting run", .{});
}

fn teleport(world: *World, player: *Entity, _: *Args, reply: []u8) []const u8 {
    const teleporter = world.getPtr(world.teleporter_id) orelse return print(
        reply,
        "no teleporter",
        .{},
    );
    const position = teleporter.transform.position;
    world.act(
        .{ .id = player.id, .verb = .{ .teleport = position + nz.vec.scale(shared.Planet.surfaceUp(position), 10) } },
    );
    return print(reply, "teleported", .{});
}

fn time(world: *World, _: *Entity, args: *Args, reply: []u8) []const u8 {
    world.run_seconds = @floatFromInt(count(args, 0));
    return print(reply, "run time {d:.0}s", .{world.run_seconds});
}

fn spawning(world: *World, _: *Entity, _: *Args, reply: []u8) []const u8 {
    world.toggle_spawning_requested = true;
    return print(reply, "toggled enemy spawning", .{});
}

fn boss(world: *World, player: *Entity, _: *Args, reply: []u8) []const u8 {
    const teleporter = world.getPtr(world.teleporter_id) orelse return print(reply, "no teleporter", .{});
    if (teleporter.teleporter.state != .idle) return print(reply, "teleporter already active", .{});
    PlayerController.activateTeleporter(world, player, teleporter) catch |err|
        return print(reply, "boss: {t}", .{err});
    return print(reply, "teleporter active", .{});
}

fn directors(world: *World, _: *Entity, _: *Args, reply: []u8) []const u8 {
    var writer: std.Io.Writer = .fixed(reply);
    writer.print("enemies {d}\n", .{world.enemyCount()}) catch {};
    for (std.enums.values(World.Director.Kind)) |kind| {
        const director = world.directors.get(kind);
        if (!director.active) continue;
        writer.print("{t} {d:.0} credits", .{ kind, director.credits }) catch break;
        if (director.wave) |wave| writer.print(" wave {t} {t} x{d}", .{ wave.enemy, wave.elite, wave.spawned }) catch break;
        writer.writeByte('\n') catch break;
    }
    return writer.buffered();
}
