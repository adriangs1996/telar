const DamageContext = @import("DamageContext.zig");
const std = @import("std");
const Fixture = @import("Fixture.zig");
const max_frame_size_module = @import("telar-core").max_frame_size;
const collectSpans_module = @import("telar-backend").collectSpans;
const main = @import("main.zig");
const encodePaneFrame_module = @import("telar-core").encodePaneFrame;
const FrameContext = @This();

damage: DamageContext,
encode_buffer: []u8,

pub fn init(gpa: std.mem.Allocator, fixture: *const Fixture) !FrameContext {
    var damage = try DamageContext.init(gpa, fixture, .fragmented);
    errdefer damage.deinit();
    const encode_buffer = try gpa.alloc(u8, max_frame_size_module);
    return .{ .damage = damage, .encode_buffer = encode_buffer };
}

pub fn deinit(context: *FrameContext) void {
    context.damage.gpa.free(context.encode_buffer);
    context.damage.deinit();
}

pub fn encode(context: *FrameContext) ![]const u8 {
    const diff = collectSpans_module(.{
        .current = context.damage.current,
        .acknowledged = context.damage.acknowledged,
        .cols = main.cols,
        .damaged_rows = context.damage.damaged_rows,
    }, context.damage.spans);
    return encodePaneFrame_module(
        context.encode_buffer,
        main.frame(2, context.damage.spans[0..diff.span_count]),
    );
}
