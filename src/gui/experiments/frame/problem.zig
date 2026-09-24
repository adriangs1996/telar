//! CHALLENGE: maintain concat(blocks[*].quads) in one contiguous, owned output.
//! Input revisions are trusted; inputs never alias output. Output survives calls.
//! No allocation, no reordering, no borrowing input pointers, no writes in flight.
//! Edit solve. rebuild is the independent reference. See README.md for examples.
const gfx = @import("gfx");
const quad = gfx.Quad;
const Block = @import("Block.zig");
const Frame = @import("Frame.zig");
const Cost = @import("Cost.zig");

pub const bytes_per_quad = @sizeOf(quad.Quad);

/// Starter solution: retain equal-sized, equal-identity blocks; rebuild on layout
/// changes. Next challenge: preserve an unchanged prefix when a later block grows.
/// Example: `const cost = try problem.solve(blocks, &frame);`
pub noinline fn solve(blocks: []const Block, frame: *Frame) !Cost {
    const total = try validate(blocks, frame);
    var cost: Cost = .{ .block_visits = blocks.len };
    var layout_changed = blocks.len != frame.count;
    for (blocks, 0..) |block, index| {
        const old = frame.previous[index];
        layout_changed = layout_changed or old.id != block.id or old.len != block.quads.len;
        cost.block_visits += 1;
    }

    var offset: usize = 0;
    for (blocks, 0..) |block, index| {
        cost.block_visits += 1;
        if (layout_changed or frame.previous[index].revision != block.revision) {
            @memcpy(frame.output[offset..][0..block.quads.len], block.quads);
            cost.quads_copied += block.quads.len;
        }

        frame.previous[index] = .{ .id = block.id, .revision = block.revision, .len = block.quads.len };
        offset += block.quads.len;
    }

    frame.count = blocks.len;
    frame.len = total;
    return cost;
}

/// Reference: concatenate every block on every call. Example: `try problem.rebuild(blocks, &frame);`
pub noinline fn rebuild(blocks: []const Block, frame: *Frame) !Cost {
    const total = try validate(blocks, frame);
    var offset: usize = 0;
    for (blocks) |block| {
        @memcpy(frame.output[offset..][0..block.quads.len], block.quads);
        offset += block.quads.len;
    }

    frame.len = total;
    return .{ .block_visits = blocks.len * 2, .quads_copied = total };
}

fn validate(blocks: []const Block, frame: *const Frame) !usize {
    if (frame.borrowed) {
        return error.FrameInFlight;
    }

    if (blocks.len > Frame.max_blocks) {
        return error.TooManyBlocks;
    }

    var total: usize = 0;
    for (blocks) |block| {
        if (block.quads.len > frame.output.len - total) {
            return error.OutputFull;
        }

        total += block.quads.len;
    }

    return total;
}
