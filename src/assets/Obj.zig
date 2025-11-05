//! OBJ (or .OBJ) is a geometry format definition file format.
//! Reference: https://en.wikipedia.org/wiki/Wavefront_.obj_file
const std = @import("std");

/// Stored as (x, y, z, [w]) coordinates.
/// ```
/// v 0.123 0.234 0.345 1.0
/// v ...
/// ...
/// ```
/// W is optional and defaults to 1.0.
vertices: std.ArrayList([4]f32) = .empty,

/// Stored as (u, [v, w]) coordinates.
/// ```
/// vt 0.500 1 [0]
/// vt ...
/// ...
/// ```
/// Values will vary between 0 and 1. V, W are optional and default to 0.
texture_coords: std.ArrayList([3]f32) = .empty,

/// Vertex normals in (x, y, z) form.
/// ```
/// vn 0.707 0.000 0.707
/// vn ...
/// ...
/// ```
/// Normals might not be unit vectors.
normals: std.ArrayList([3]f32) = .empty,

/// Collection of all faces in the model.
/// Faces are defined using lists of vertex, texture and normal indices in the format vertex_index/texture_index/normal_index
/// for which each index starts at 1 and increases corresponding to the order in which the referenced element was defined.
faces: std.ArrayList(Face) = .empty,

/// `l v1 v2 v3 v4 v5 v6 ...`
/// Records the order of vertices which build a polyline.
lines: std.ArrayList(std.ArrayList(i32)) = .empty,

/// `o [object name]`
current_object: ?[]const u8 = null,

/// `g [group name]`
current_group: ?[]const u8 = null,

gpa: std.mem.Allocator,

pub const Face = struct {
    /// A valid vertex index matches the corresponding vertex elements of a previously defined vertex list.
    /// If an index is positive then it refers to the offset in that vertex list, starting at 1. If an index is
    /// negative then it relatively refers to the end of the vertex list, -1 referring to the last element.
    /// `f v1 v2 v3 ...`
    vertex_indices: std.ArrayList(i32) = .empty,

    /// Optionally, texture coordinate indices can be used to specify texture coordinates when defining a face.
    /// A valid texture coordinate index starts from 1 and matches the corresponding element in the previously
    /// defined list of texture coordinates. Each face can contain three or more elements.
    /// `f v1/vt1 v2/vt2 v3/vt3 ...`
    texture_indices: std.ArrayList(i32) = .empty,

    /// Optionally, normal indices can be used to specify normal vectors for vertices when defining a face.
    /// A valid normal index starts from 1 and matches the corresponding element in the previously defined list of normals.
    /// Each face can contain three or more elements.
    /// `f v1/vt1/vn1 v2/vt2/vn2 v3/vt3/vn3 ...`
    normal_indices: std.ArrayList(i32) = .empty,

    pub const init: Face = .{};
};

/// Deinit with `deinit`.
pub fn init(gpa: std.mem.Allocator) Obj {
    return .{ .gpa = gpa };
}

pub fn deinit(o: *Obj) void {
    // Vertex data arrays.
    o.vertices.deinit(o.gpa);
    o.texture_coords.deinit(o.gpa);
    o.normals.deinit(o.gpa);

    // Faces.
    for (o.faces.items) |*face| {
        face.vertex_indices.deinit(o.gpa);
        face.texture_indices.deinit(o.gpa);
        face.normal_indices.deinit(o.gpa);
    }
    o.faces.deinit(o.gpa);

    // Line elements.
    for (o.lines.items) |*line| {
        line.deinit(o.gpa);
    }
    o.lines.deinit(o.gpa);

    if (o.current_object) |obj| {
        o.gpa.free(obj);
    }
    if (o.current_group) |grp| {
        o.gpa.free(grp);
    }
}

pub fn parseSlice(o: *Obj, slice: []const u8) !void {
    var it = std.mem.tokenizeAny(u8, slice, "\n");

    while (it.next()) |line| {
        if (line.len == 0) continue;

        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (trimmed.len == 0) continue;

        // > Anything following a hash character (#) is a comment.
        if (trimmed[0] == '#') continue;

        try o.parseSliceSingle(trimmed);
    }
}

/// Parse a single line.
fn parseSliceSingle(o: *Obj, slice: []const u8) !void {
    var it = std.mem.tokenizeAny(u8, slice, " \t");

    // Get the command token, which is the first element on the first line.
    // If no tokens exist, skip the line, which shouldn't really happen after trimming.
    const command_slice = it.next() orelse return;

    // Convert command to an enum so it does not look so ugly.
    const command = std.meta.stringToEnum(enum {
        /// List of geometric vertices.
        v,
        /// List of texture coordinates.
        vt,
        /// List of vertex normals.
        vn,
        /// Polygonal face element.
        f,
        /// Line elements.
        l,
        /// Named objects.
        o,
        /// Polygon groups.
        g,
        unknown,
    }, command_slice) orelse .unknown;

    try switch (command) {
        .v => o.parseVertex(&it),
        .vt => o.parseTextureCoord(&it),
        .vn => o.parseNormal(&it),
        .f => o.parseFace(&it),
        .l => o.parseLineElement(&it),
        .o => o.parseObject(&it),
        .g => o.parseGroup(&it),
        // Don't care about unknown commands.
        .unknown => {},
    };
}

/// `v x y z [w]` where w is optional.
fn parseVertex(o: *Obj, it: *std.mem.TokenIterator(u8, .any)) !void {
    var vertex: [4]f32 = .{ 0, 0, 0, 1.0 };

    // X.
    const x = it.next() orelse return error.InvalidVertex;
    vertex[0] = try std.fmt.parseFloat(f32, x);

    // Y.
    const y = it.next() orelse return error.InvalidVertex;
    vertex[1] = try std.fmt.parseFloat(f32, y);

    // Z.
    const z = it.next() orelse return error.InvalidVertex;
    vertex[2] = try std.fmt.parseFloat(f32, z);

    // W.
    if (it.next()) |w| {
        vertex[3] = try std.fmt.parseFloat(f32, w);
    }

    try o.vertices.append(o.gpa, vertex);
}

/// `vt u [v] [w]` where v and w are optional.
fn parseTextureCoord(o: *Obj, it: *std.mem.TokenIterator(u8, .any)) !void {
    var texture_coord: [3]f32 = @splat(0);

    // Horizontal texture coordinate.
    const u = it.next() orelse return error.InvalidTextureCoord;
    texture_coord[0] = try std.fmt.parseFloat(f32, u);

    // Vertical texture coordinate.
    if (it.next()) |v| {
        texture_coord[1] = try std.fmt.parseFloat(f32, v);

        // Depth texture coordinate.
        if (it.next()) |w| {
            texture_coord[2] = try std.fmt.parseFloat(f32, w);
        }
    }

    try o.texture_coords.append(o.gpa, texture_coord);
}

/// `vn x y z`.
fn parseNormal(o: *Obj, it: *std.mem.TokenIterator(u8, .any)) !void {
    // Nothing here is optional! Very evil.
    var normal: [3]f32 = undefined;

    // X.
    const x = it.next() orelse return error.InvalidNormal;
    normal[0] = try std.fmt.parseFloat(f32, x);

    // Y.
    const y = it.next() orelse return error.InvalidNormal;
    normal[1] = try std.fmt.parseFloat(f32, y);

    // Z.
    const z = it.next() orelse return error.InvalidNormal;
    normal[2] = try std.fmt.parseFloat(f32, z);

    try o.normals.append(o.gpa, normal);
}

/// `f v1[/vt1][/vn1] v2[/vt2][/vn2] v3[/vt3][/vn3] ...`
fn parseFace(o: *Obj, it: *std.mem.TokenIterator(u8, .any)) !void {
    var face: Face = .init;

    // All vertices in a face should have the same format.
    var has_texture = false;
    var has_normal = false;
    var first_vertex = true;

    // > Each face can contain three or more vertices
    while (it.next()) |vertex| {
        // Eeither `v`, `v/vt`, `v//vn`, or `v/vt/vn`
        var part = std.mem.splitScalar(u8, vertex, '/');
        var parts: usize = 0;
        var indices: [3]?i32 = @splat(null);

        // Count parts and handle the '//' case for v//vn format.
        // The '//' thingy means missing texture coordinates.
        var slashes: usize = 0;
        for (vertex) |c| {
            if (c == '/') slashes += 1;
        }

        // Vertex index.
        if (part.next()) |v| {
            indices[0] = try std.fmt.parseInt(
                i32,
                v,
                // base
                10,
            );
            parts += 1;
        }

        // Texture coordinate.
        if (part.next()) |vt| {
            if (vt.len > 0) {
                indices[1] = try std.fmt.parseInt(
                    i32,
                    vt,
                    // base
                    10,
                );
                has_texture = true;
            }
            parts += 1;
        } else if (slashes == 2) {
            // No texture coordinate.
            parts += 1;
        }

        // Normal index.
        if (part.next()) |vn| {
            indices[2] = try std.fmt.parseInt(
                i32,
                vn,
                // base
                10,
            );
            has_normal = true;
            parts += 1;
        }

        // OBJ uses 1-based index, while we are using 0-based, so we need to convert between these two.
        if (indices[0]) |v| {
            const index = if (v > 0) v - 1 else @as(i32, @intCast(o.vertices.items.len)) + v;
            try face.vertex_indices.append(o.gpa, index);
        }

        // Either all vertices have texture or none.
        if (has_texture) {
            if (indices[1]) |vt| {
                const index = if (vt > 0) vt - 1 else @as(i32, @intCast(o.texture_coords.items.len)) + vt;
                try face.texture_indices.append(o.gpa, index);
            } else {
                try face.texture_indices.append(o.gpa, -1);
            }
        }

        if (has_normal) {
            if (indices[2]) |vn| {
                const index = if (vn > 0) vn - 1 else @as(i32, @intCast(o.normals.items.len)) + vn;
                try face.normal_indices.append(o.gpa, index);
            } else {
                try face.normal_indices.append(o.gpa, -1);
            }
        }

        first_vertex = false;
    }

    if (face.vertex_indices.items.len < 3) {
        face.vertex_indices.deinit(o.gpa);
        face.texture_indices.deinit(o.gpa);
        face.normal_indices.deinit(o.gpa);
        return error.InvalidFace;
    }

    try o.faces.append(o.gpa, face);
}

/// `l v1 v2 v3 ...`
fn parseLineElement(o: *Obj, it: *std.mem.TokenIterator(u8, .any)) !void {
    var line: std.ArrayList(i32) = .empty;

    // Vertex indices for the line. Lines need at least 2 vertices to be valid, and each vertex reference
    // creates a segment to the next.
    while (it.next()) |v| {
        const index = try std.fmt.parseInt(
            i32,
            v,
            // base
            10,
        );

        const actual_index = if (index > 0) index - 1 else @as(i32, @intCast(o.vertices.items.len)) + index;

        try line.append(o.gpa, actual_index);
    }

    // Minimum for a line segment is 2.
    if (line.items.len < 2) {
        line.deinit(o.gpa);
        return error.InvalidLine;
    }

    try o.lines.append(o.gpa, line);
}

fn parseObject(o: *Obj, it: *std.mem.TokenIterator(u8, .any)) !void {
    // Only one object can be active at a time, so free any existing object name to not leak anything.
    if (o.current_object) |object| {
        o.gpa.free(object);
    }

    const name = it.rest();
    if (name.len == 0) {
        o.current_object = null;
        return;
    }

    const current_object = try o.gpa.dupe(u8, name);
    o.current_object = current_object;
}

fn parseGroup(o: *Obj, it: *std.mem.TokenIterator(u8, .any)) !void {
    if (o.current_group) |group| {
        o.gpa.free(group);
    }

    const name = it.rest();
    if (name.len == 0) {
        o.current_group = null;
        return;
    }

    const current_group = try o.gpa.dupe(u8, name);
    o.current_group = current_group;
}

test Obj {
    const gpa = std.testing.allocator;

    {
        var obj: Obj = .init(gpa);
        defer obj.deinit();

        const data =
            \\# This is a comment
            \\o TestObject
            \\v 1.0 2.0 3.0
            \\v -1.0 -2.0 -3.0 0.5
            \\v 0.5 0.5 0.5
            \\
            \\vt 0.5 0.5
            \\vt 1.0 0.0 0.5
            \\vt 0.25
            \\
            \\vn 0.0 1.0 0.0
            \\vn 1.0 0.0 0.0
            \\vn 0.707 0.707 0.0
            \\
            \\g TestGroup
            \\f 1/1/1 2/2/2 3/3/3
            \\f 1//1 2//2 3//3
            \\f 1/1 2/2 3/3
            \\f 1 2 3
            \\f -3/-3/-3 -2/-2/-2 -1/-1/-1
            \\
            \\l 1 2 3 -1
            \\l 2 3
        ;

        try obj.parseSlice(data);

        try std.testing.expectEqual(3, obj.vertices.items.len);
        try std.testing.expectEqual([4]f32{ 1.0, 2.0, 3.0, 1.0 }, obj.vertices.items[0]);
        try std.testing.expectEqual([4]f32{ -1.0, -2.0, -3.0, 0.5 }, obj.vertices.items[1]);
        try std.testing.expectEqual([4]f32{ 0.5, 0.5, 0.5, 1.0 }, obj.vertices.items[2]);

        try std.testing.expectEqual(3, obj.texture_coords.items.len);
        try std.testing.expectEqual([3]f32{ 0.5, 0.5, 0.0 }, obj.texture_coords.items[0]);
        try std.testing.expectEqual([3]f32{ 1.0, 0.0, 0.5 }, obj.texture_coords.items[1]);
        try std.testing.expectEqual([3]f32{ 0.25, 0.0, 0.0 }, obj.texture_coords.items[2]);

        try std.testing.expectEqual(3, obj.normals.items.len);
        try std.testing.expectEqual([3]f32{ 0.0, 1.0, 0.0 }, obj.normals.items[0]);
        try std.testing.expectEqual([3]f32{ 1.0, 0.0, 0.0 }, obj.normals.items[1]);
        try std.testing.expectEqual([3]f32{ 0.707, 0.707, 0.0 }, obj.normals.items[2]);

        try std.testing.expectEqual(5, obj.faces.items.len);

        try std.testing.expectEqualSlices(i32, &.{ 0, 1, 2 }, obj.faces.items[0].vertex_indices.items);
        try std.testing.expectEqualSlices(i32, &.{ 0, 1, 2 }, obj.faces.items[0].texture_indices.items);
        try std.testing.expectEqualSlices(i32, &.{ 0, 1, 2 }, obj.faces.items[0].normal_indices.items);

        try std.testing.expectEqualSlices(i32, &.{ 0, 1, 2 }, obj.faces.items[1].vertex_indices.items);
        try std.testing.expectEqual(0, obj.faces.items[1].texture_indices.items.len);
        try std.testing.expectEqualSlices(i32, &.{ 0, 1, 2 }, obj.faces.items[1].normal_indices.items);

        try std.testing.expectEqualSlices(i32, &.{ 0, 1, 2 }, obj.faces.items[2].vertex_indices.items);
        try std.testing.expectEqualSlices(i32, &.{ 0, 1, 2 }, obj.faces.items[2].texture_indices.items);
        try std.testing.expectEqual(0, obj.faces.items[2].normal_indices.items.len);

        try std.testing.expectEqualSlices(i32, &.{ 0, 1, 2 }, obj.faces.items[3].vertex_indices.items);
        try std.testing.expectEqual(0, obj.faces.items[3].texture_indices.items.len);
        try std.testing.expectEqual(0, obj.faces.items[3].normal_indices.items.len);

        try std.testing.expectEqualSlices(i32, &.{ 0, 1, 2 }, obj.faces.items[4].vertex_indices.items);
        try std.testing.expectEqualSlices(i32, &.{ 0, 1, 2 }, obj.faces.items[4].texture_indices.items);
        try std.testing.expectEqualSlices(i32, &.{ 0, 1, 2 }, obj.faces.items[4].normal_indices.items);

        try std.testing.expectEqual(2, obj.lines.items.len);
        try std.testing.expectEqualSlices(i32, &.{ 0, 1, 2, 2 }, obj.lines.items[0].items);
        try std.testing.expectEqualSlices(i32, &.{ 1, 2 }, obj.lines.items[1].items);

        try std.testing.expectEqualStrings("TestObject", obj.current_object.?);
        try std.testing.expectEqualStrings("TestGroup", obj.current_group.?);
    }
}

const Obj = @This();
