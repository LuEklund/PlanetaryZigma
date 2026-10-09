const std = @import("std");

const pointer_depth: u32 = 4;

pub fn hash(comptime types: []const type) u64 {
    return comptime typesHash(types);
}

fn typesHash(comptime types: []const type) u64 {
    @setEvalBranchQuota(10_000_000);
    var hasher: std.hash.Fnv1a_64 = .init();
    for (types) |T| feed(&hasher, typeHash(T, pointer_depth));
    return hasher.final();
}

fn feed(hasher: *std.hash.Fnv1a_64, value: u64) void {
    hasher.update(std.mem.asBytes(&value));
}

fn typeHash(comptime T: type, comptime depth: u32) u64 {
    comptime {
        @setEvalBranchQuota(10_000_000);
        var hasher: std.hash.Fnv1a_64 = .init();
        hasher.update(@tagName(@typeInfo(T)));
        switch (@typeInfo(T)) {
            .type, .comptime_int, .comptime_float, .enum_literal, .undefined, .null, .noreturn, .@"fn", .@"opaque", .frame, .@"anyframe" => return hasher.final(),
            else => {},
        }
        feed(&hasher, @sizeOf(T));
        feed(&hasher, @alignOf(T));
        switch (@typeInfo(T)) {
            .@"struct" => |info| for (info.fields) |field| {
                if (field.is_comptime) continue;
                hasher.update(field.name);
                feed(&hasher, @bitOffsetOf(T, field.name));
                feed(&hasher, typeHash(field.type, depth));
            },
            .@"union" => |info| {
                if (info.tag_type) |Tag| feed(&hasher, typeHash(Tag, depth));
                for (info.fields) |field| {
                    hasher.update(field.name);
                    feed(&hasher, typeHash(field.type, depth));
                }
            },
            .@"enum" => |info| {
                feed(&hasher, typeHash(info.tag_type, depth));
                for (info.fields) |field| {
                    hasher.update(field.name);
                    feed(&hasher, @as(u64, @truncate(@as(u128, @bitCast(@as(i128, field.value))))));
                }
            },
            .array => |info| {
                feed(&hasher, info.len);
                feed(&hasher, typeHash(info.child, depth));
            },
            .vector => |info| {
                feed(&hasher, info.len);
                feed(&hasher, typeHash(info.child, depth));
            },
            .optional => |info| feed(&hasher, typeHash(info.child, depth)),
            .error_union => |info| feed(&hasher, typeHash(info.payload, depth)),
            .pointer => |info| {
                hasher.update(@tagName(info.size));
                if (depth > 0) feed(&hasher, typeHash(info.child, depth - 1));
            },
            else => {},
        }
        return hasher.final();
    }
}

test "layout hash sees field order and size" {
    const A = struct { x: u32, y: u64 };
    const B = struct { y: u64, x: u32 };
    const C = struct { x: u32, y: u32 };
    try std.testing.expect(hash(&.{A}) != hash(&.{B}));
    try std.testing.expect(hash(&.{A}) != hash(&.{C}));
    try std.testing.expectEqual(hash(&.{A}), hash(&.{struct { x: u32, y: u64 }}));
}
