const grad3 = [12][3]f32{
    .{ 1, 1, 0 }, .{ -1, 1, 0 }, .{ 1, -1, 0 }, .{ -1, -1, 0 },
    .{ 1, 0, 1 }, .{ -1, 0, 1 }, .{ 1, 0, -1 }, .{ -1, 0, -1 },
    .{ 0, 1, 1 }, .{ 0, -1, 1 }, .{ 0, 1, -1 }, .{ 0, -1, -1 },
};

const perm = blk: {
    const p = [_]u8{
        151, 160, 137, 91,  90,  15,  131, 13,  201, 95,  96,  53,  194, 233, 7,   225,
        140, 36,  103, 30,  69,  142, 8,   99,  37,  240, 21,  10,  23,  190, 6,   148,
        247, 120, 234, 75,  0,   26,  197, 62,  94,  252, 219, 203, 117, 35,  11,  32,
        57,  177, 33,  88,  237, 149, 56,  87,  174, 20,  125, 136, 171, 168, 68,  175,
        74,  165, 71,  134, 139, 48,  27,  166, 77,  146, 158, 231, 83,  111, 229, 122,
        60,  211, 133, 230, 220, 105, 92,  41,  55,  46,  245, 40,  244, 102, 143, 54,
        65,  25,  63,  161, 1,   216, 80,  73,  209, 76,  132, 187, 208, 89,  18,  169,
        200, 196, 135, 130, 116, 188, 159, 86,  164, 100, 109, 198, 173, 186, 3,   64,
        52,  217, 226, 250, 124, 123, 5,   202, 38,  147, 118, 126, 255, 82,  85,  212,
        207, 206, 59,  227, 47,  16,  58,  17,  182, 189, 28,  42,  223, 183, 170, 213,
        119, 248, 152, 2,   44,  154, 163, 70,  221, 153, 101, 155, 167, 43,  172, 9,
        129, 22,  39,  253, 19,  98,  108, 110, 79,  113, 224, 232, 178, 185, 112, 104,
        218, 246, 97,  228, 251, 34,  242, 193, 238, 210, 144, 12,  191, 179, 162, 241,
        81,  51,  145, 235, 249, 14,  239, 107, 49,  192, 214, 31,  181, 199, 106, 157,
        184, 84,  204, 176, 115, 121, 50,  45,  127, 4,   150, 254, 138, 236, 205, 93,
        222, 114, 67,  29,  24,  72,  243, 141, 128, 195, 78,  66,  215, 61,  156, 180,
    };
    var p2: [512]u8 = undefined;
    for (0..256) |i| {
        p2[i] = p[i];
        p2[i + 256] = p[i];
    }
    break :blk p2;
};

fn dot3(g: [3]f32, x: f32, y: f32, z: f32) f32 {
    return g[0] * x + g[1] * y + g[2] * z;
}

pub fn simplex3(xin: f32, yin: f32, zin: f32) f32 {
    const F3 = 1.0 / 3.0;
    const G3 = 1.0 / 6.0;

    const s = (xin + yin + zin) * F3;
    const i: i32 = @intFromFloat(@floor(xin + s));
    const j: i32 = @intFromFloat(@floor(yin + s));
    const k: i32 = @intFromFloat(@floor(zin + s));

    const t = @as(f32, @floatFromInt(i + j + k)) * G3;
    const x0 = xin - (@as(f32, @floatFromInt(i)) - t);
    const y0 = yin - (@as(f32, @floatFromInt(j)) - t);
    const z0 = zin - (@as(f32, @floatFromInt(k)) - t);

    var i_1: i32 = 0;
    var j_1: i32 = 0;
    var k_1: i32 = 0;
    var i_2: i32 = 0;
    var j_2: i32 = 0;
    var k_2: i32 = 0;
    if (x0 >= y0) {
        if (y0 >= z0) {
            i_1 = 1;
            j_1 = 0;
            k_1 = 0;
            i_2 = 1;
            j_2 = 1;
            k_2 = 0;
        } else if (x0 >= z0) {
            i_1 = 1;
            j_1 = 0;
            k_1 = 0;
            i_2 = 1;
            j_2 = 0;
            k_2 = 1;
        } else {
            i_1 = 0;
            j_1 = 0;
            k_1 = 1;
            i_2 = 1;
            j_2 = 0;
            k_2 = 1;
        }
    } else {
        if (y0 < z0) {
            i_1 = 0;
            j_1 = 0;
            k_1 = 1;
            i_2 = 0;
            j_2 = 1;
            k_2 = 1;
        } else if (x0 < z0) {
            i_1 = 0;
            j_1 = 1;
            k_1 = 0;
            i_2 = 0;
            j_2 = 1;
            k_2 = 1;
        } else {
            i_1 = 0;
            j_1 = 1;
            k_1 = 0;
            i_2 = 1;
            j_2 = 1;
            k_2 = 0;
        }
    }

    const x1 = x0 - @as(f32, @floatFromInt(i_1)) + G3;
    const y1 = y0 - @as(f32, @floatFromInt(j_1)) + G3;
    const z1 = z0 - @as(f32, @floatFromInt(k_1)) + G3;
    const x2 = x0 - @as(f32, @floatFromInt(i_2)) + 2.0 * G3;
    const y2 = y0 - @as(f32, @floatFromInt(j_2)) + 2.0 * G3;
    const z2 = z0 - @as(f32, @floatFromInt(k_2)) + 2.0 * G3;
    const x3 = x0 - 1.0 + 3.0 * G3;
    const y3 = y0 - 1.0 + 3.0 * G3;
    const z3 = z0 - 1.0 + 3.0 * G3;

    const ii: usize = @intCast(@mod(i, 256));
    const jj: usize = @intCast(@mod(j, 256));
    const kk: usize = @intCast(@mod(k, 256));

    const gi0 = perm[ii + perm[jj + perm[kk]]] % 12;
    const gi1 = perm[ii + @as(usize, @intCast(i_1)) + perm[jj + @as(usize, @intCast(j_1)) + perm[kk + @as(usize, @intCast(k_1))]]] % 12;
    const gi2 = perm[ii + @as(usize, @intCast(i_2)) + perm[jj + @as(usize, @intCast(j_2)) + perm[kk + @as(usize, @intCast(k_2))]]] % 12;
    const gi3 = perm[ii + 1 + perm[jj + 1 + perm[kk + 1]]] % 12;

    var n0: f32 = 0;
    var n1: f32 = 0;
    var n2: f32 = 0;
    var n3: f32 = 0;
    var t0 = 0.6 - x0 * x0 - y0 * y0 - z0 * z0;
    if (t0 > 0) {
        t0 *= t0;
        n0 = t0 * t0 * dot3(grad3[gi0], x0, y0, z0);
    }
    var t1 = 0.6 - x1 * x1 - y1 * y1 - z1 * z1;
    if (t1 > 0) {
        t1 *= t1;
        n1 = t1 * t1 * dot3(grad3[gi1], x1, y1, z1);
    }
    var t2 = 0.6 - x2 * x2 - y2 * y2 - z2 * z2;
    if (t2 > 0) {
        t2 *= t2;
        n2 = t2 * t2 * dot3(grad3[gi2], x2, y2, z2);
    }
    var t3 = 0.6 - x3 * x3 - y3 * y3 - z3 * z3;
    if (t3 > 0) {
        t3 *= t3;
        n3 = t3 * t3 * dot3(grad3[gi3], x3, y3, z3);
    }

    return 32.0 * (n0 + n1 + n2 + n3);
}
