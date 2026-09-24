const std = @import("std");
const gfx = @import("gfx");
const quad = gfx.Quad;
const problem = @import("problem.zig");
const Block = @import("Block.zig");
const Frame = @import("Frame.zig");
const Cost = @import("Cost.zig");
const Self = @This();

pub const Action = enum { repeat, edit, grow, shrink, swap, reset };

a: [4]quad.Quad = undefined,
b: [2]quad.Quad = undefined,
output: [6]quad.Quad = undefined,
expected: [6]quad.Quad = undefined,
frame: Frame = .{ .output = &.{} },
a_len: usize = 3,
revision: u64 = 1,
reversed: bool = false,
steps: usize = 0,
cost: Cost = .{},
reference_cost: Cost = .{},

/// Call only after the Demo reaches its final address. Example: `try demo.step(.reset);`
pub fn step(self: *Self, action: Action) !void {
    if (action == .reset or self.steps == 0) {
        self.* = .{};
        for (&self.a, 0..) |*item, index| {
            item.* = std.mem.zeroes(quad.Quad);
            item.x = @floatFromInt(index + 1);
        }

        for (&self.b, 0..) |*item, index| {
            item.* = std.mem.zeroes(quad.Quad);
            item.x = @floatFromInt(index + 8);
        }

        self.frame.output = &self.output;
    } else {
        switch (action) {
            .repeat => {},
            .edit => {
                self.a[0].x += 10;
                self.revision += 1;
            },
            .grow => {
                self.a_len = @min(self.a.len, self.a_len + 1);
                self.revision += 1;
            },
            .shrink => {
                self.a_len -|= 1;
                self.revision += 1;
            },
            .swap => self.reversed = !self.reversed,
            .reset => unreachable,
        }
    }

    var blocks = [_]Block{
        .{ .id = 1, .revision = self.revision, .quads = self.a[0..self.a_len] },
        .{ .id = 2, .revision = 1, .quads = &self.b },
    };
    if (self.reversed) {
        std.mem.swap(Block, &blocks[0], &blocks[1]);
    }

    var reference: Frame = .{ .output = &self.expected };
    self.reference_cost = try problem.rebuild(&blocks, &reference);
    self.cost = try problem.solve(&blocks, &self.frame);
    if (reference.len != self.frame.len or !std.mem.eql(u8, std.mem.sliceAsBytes(self.expected[0..reference.len]), std.mem.sliceAsBytes(self.output[0..self.frame.len]))) {
        return error.IncorrectSolution;
    }

    self.steps += 1;
}
