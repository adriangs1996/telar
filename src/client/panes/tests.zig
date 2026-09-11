const InitialType = @import("Initial.zig");
const FrameInput = @import("FrameInput.zig");
const FrameViewType = @import("telar-core").FrameView;
const CellType = @import("telar-core").Cell;
const SpanType = @import("telar-core").Span;
const encodePaneFrame_module = @import("telar-core").encodePaneFrame;
const decodeServer_module = @import("telar-core").decodeServer;
const Pane = @import("Pane.zig");
const std = @import("std");
const PresentationCommitType = @import("PresentationCommit.zig");

const initial: InitialType = .{
    .spec = .{
        .pane_id = @enumFromInt(1),
        .location = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(1) },
        .size = .{ .cols = 2, .rows = 2 },
    },
    .attached = true,
};

fn frame(storage: []u8, input: FrameInput) !FrameViewType {
    var cells = [_]CellType{.{}} ** 9;
    cells[0].bytes[0] = input.character;
    const count = if (input.base == 0) @as(usize, input.cols) * input.rows else 1;
    const spans = [_]SpanType{.{ .start = 0, .cells = cells[0..count] }};
    const bytes = try encodePaneFrame_module(storage, .{
        .pane_id = input.pane_id,
        .frame_id = input.id,
        .base_frame_id = input.base,
        .cols = input.cols,
        .rows = input.rows,
        .cursor = .{ .visible = true, .x = 1, .y = 0 },
        .mouse = .{ .tracking = .normal, .sgr = true },
        .input_modes = .{ .cursor_keys = true, .bracketed_paste = true },
        .pointer_shape = .pointer,
        .scroll = .{ .total_rows = input.rows, .offset = 0 },
        .spans = &spans,
    });
    return (try decodeServer_module(bytes)).pane_frame;
}

test "pane snapshot owns cells and child modes independently of the receive buffer" {
    var pane = try Pane.init(std.testing.allocator, initial);
    defer pane.deinit();
    var bytes: [1024]u8 = undefined;
    const applied = try pane.applyFrame(try frame(&bytes, .{}));
    @memset(&bytes, 0);
    try std.testing.expectEqual(@as(u64, 4), applied.cells);
    try std.testing.expectEqualStrings("a", pane.buffer.cells[0].text());
    try std.testing.expect(pane.input_modes.cursor_keys);
    try std.testing.expect(pane.input_modes.bracketed_paste);
    try std.testing.expect(pane.mouse.sgr);
    try std.testing.expectEqual(.pointer, pane.pointer_shape);
    try std.testing.expect(pane.cursor.visible);
}

test "pane rejects another identity and a broken patch base without mutation" {
    var pane = try Pane.init(std.testing.allocator, initial);
    defer pane.deinit();
    var bytes: [1024]u8 = undefined;
    _ = try pane.applyFrame(try frame(&bytes, .{}));
    try std.testing.expectError(error.FrameBaseMismatch, pane.applyFrame(try frame(&bytes, .{ .id = 3, .base = 2, .character = 'b' })));
    try std.testing.expectError(error.PaneMismatch, pane.applyFrame(try frame(&bytes, .{ .pane_id = @enumFromInt(2) })));
    try std.testing.expectEqual(@as(u64, 1), pane.applied_frame_id);
    try std.testing.expectEqualStrings("a", pane.buffer.cells[0].text());
}

test "an obsolete presentation cannot retire newer pane damage" {
    var pane = try Pane.init(std.testing.allocator, initial);
    defer pane.deinit();
    var bytes: [1024]u8 = undefined;
    _ = try pane.applyFrame(try frame(&bytes, .{}));
    var commit: PresentationCommitType = .{ .location = initial.spec.location };
    commit.append(&pane);
    _ = try pane.applyFrame(try frame(&bytes, .{ .id = 2, .base = 1, .character = 'b' }));
    pane.commitPresentation(commit.slice()[0].frame_id);
    try std.testing.expectEqual(@as(u64, 2), pane.pending_frame_id);
    try std.testing.expect(pane.damage_rows[0].dirty());
    pane.commitPresentation(2);
    try std.testing.expectEqual(@as(u64, 0), pane.pending_frame_id);
    try std.testing.expect(!pane.damage_rows[0].dirty());
}

test "only a snapshot can resize pane storage" {
    var pane = try Pane.init(std.testing.allocator, initial);
    defer pane.deinit();
    var bytes: [1024]u8 = undefined;
    _ = try pane.applyFrame(try frame(&bytes, .{}));
    try std.testing.expectError(error.PatchSizeMismatch, pane.applyFrame(try frame(&bytes, .{ .id = 2, .base = 1, .cols = 3 })));
    try std.testing.expectEqual(@as(u16, 2), pane.buffer.w);
    _ = try pane.applyFrame(try frame(&bytes, .{ .id = 3, .cols = 3, .rows = 3 }));
    try std.testing.expectEqual(@as(u16, 3), pane.buffer.w);
    try std.testing.expectEqual(@as(usize, 3), pane.damage_rows.len);
}

test "same-size frame admission allocates no additional storage" {
    var storage: [4096]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&storage);
    var pane = try Pane.init(allocator.allocator(), initial);
    defer pane.deinit();
    const used = allocator.end_index;
    var bytes: [1024]u8 = undefined;
    _ = try pane.applyFrame(try frame(&bytes, .{}));
    for (2..100) |id| {
        _ = try pane.applyFrame(try frame(&bytes, .{ .id = id, .base = id - 1 }));
    }

    try std.testing.expectEqual(used, allocator.end_index);
}

fn exerciseAllocationFailures(gpa: std.mem.Allocator) !void {
    var pane = try Pane.init(gpa, initial);
    defer pane.deinit();
    var bytes: [1024]u8 = undefined;
    _ = pane.applyFrame(try frame(&bytes, .{ .cols = 3, .rows = 3 })) catch |err| {
        try std.testing.expectEqual(@as(u16, 2), pane.buffer.w);
        try std.testing.expectEqual(@as(usize, 2), pane.damage_rows.len);
        try std.testing.expectEqual(@as(u64, 0), pane.applied_frame_id);
        return err;
    };
    _ = try pane.setCwd("/work/telar");
    _ = try pane.setTitle("editor");
}

test "pane initialization resize and metadata roll back allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseAllocationFailures, .{});
}
