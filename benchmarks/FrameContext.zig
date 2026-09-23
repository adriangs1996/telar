const core = @import("telar-core");
const backend = @import("telar-backend");
const DamageContext = @import("DamageContext.zig");
const std = @import("std");
const Fixture = @import("Fixture.zig");
const main = @import("main.zig");
const FrameContext = @This();

damage: DamageContext,
encode_buffer: []u8,

pub fn init(gpa: std.mem.Allocator, fixture: *const Fixture) !FrameContext {
    var damage = try DamageContext.init(gpa, fixture, .fragmented);
    errdefer damage.deinit();
    const encode_buffer = try gpa.alloc(u8, core.max_frame_size);
    return .{ .damage = damage, .encode_buffer = encode_buffer };
}

pub fn deinit(self: *FrameContext) void {
    self.damage.gpa.free(self.encode_buffer);
    self.damage.deinit();
}

pub fn encode(self: *FrameContext) ![]const u8 {
    const diff = backend.collectSpans(.{
        .current = self.damage.current,
        .acknowledged = self.damage.acknowledged,
        .cols = main.cols,
        .damaged_rows = self.damage.damaged_rows,
    }, self.damage.spans);
    return core.encodePaneFrame(
        self.encode_buffer,
        main.frame(2, self.damage.spans[0..diff.span_count]),
    );
}
