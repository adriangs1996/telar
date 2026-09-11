const FrameContext = @This();
const DamageContext = @import("DamageContext.zig");
const std = @import("std");
const Fixture = @import("Fixture.zig");
const core = @import("telar-core");
const backend = @import("telar-backend");
const source_namespace = @import("main.zig");
damage: DamageContext,
encode_buffer: []u8,

fn init(gpa: std.mem.Allocator, fixture: *const Fixture) !FrameContext {
    var damage = try DamageContext.init(gpa, fixture, .fragmented);
    errdefer damage.deinit();
    const encode_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
    return .{ .damage = damage, .encode_buffer = encode_buffer };
}

fn deinit(context: *FrameContext) void {
    context.damage.gpa.free(context.encode_buffer);
    context.damage.deinit();
}

fn encode(context: *FrameContext) ![]const u8 {
    const diff = backend.damage.collectSpans(.{
        .current = context.damage.current,
        .acknowledged = context.damage.acknowledged,
        .cols = source_namespace.cols,
        .damaged_rows = context.damage.damaged_rows,
    }, context.damage.spans);
    return source_namespace.schema.encodePaneFrame(
        context.encode_buffer,
        source_namespace.frame(2, context.damage.spans[0..diff.span_count]),
    );
}
