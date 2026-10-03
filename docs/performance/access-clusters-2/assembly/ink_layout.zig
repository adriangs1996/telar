const gfx = @import("gfx");
const Quad = gfx.Quad.Quad;
const std = @import("std");

export fn gather_aos(destination: [*]Quad, source: [*]const [2]Quad, count: usize) void {
    for (0..count) |index| {
        destination[index] = source[index][1];
    }
}

export fn gather_soa(destination: [*]Quad, source: [*]const Quad, count: usize) void {
    for (0..count) |index| {
        destination[index] = source[index];
    }
}

test "role columns preserve every quad byte" {
    var source: [17][2]Quad = undefined;
    var ink: [17]Quad = undefined;
    var aos: [17]Quad = undefined;
    var soa: [17]Quad = undefined;
    var random = std.Random.DefaultPrng.init(713);
    random.random().bytes(std.mem.asBytes(&source));
    for (source, 0..) |cell, index| {
        ink[index] = cell[1];
    }
    gather_aos(&aos, &source, source.len);
    gather_soa(&soa, &ink, ink.len);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&aos), std.mem.asBytes(&soa));
}
