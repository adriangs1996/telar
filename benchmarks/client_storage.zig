//! Requested bytes, not allocator overhead or RSS. Use the same fixture on both revisions.
const std = @import("std");
const client = @import("telar-client");
const core = @import("telar-core");

/// Reports fixed capacity separately from live pane payloads. Example: `try client_storage.report(writer, gpa);`
pub fn report(writer: *std.Io.Writer, gpa: std.mem.Allocator) !void {
    inline for (.{ client.AttachedClient, client.Model, client.TabsModel, client.Tab, client.MultiplexerModel, client.Pane }) |T| {
        try writer.print("{{\"type\":\"size\",\"name\":\"{s}\",\"bytes\":{d}}}\n", .{ @typeName(T), @sizeOf(T) });
    }

    for ([_]usize{ 0, 1, 8, core.max_panes_per_tab }) |count| {
        var accounting = std.testing.FailingAllocator.init(gpa, .{});
        const allocator = accounting.allocator();
        const model = try allocator.create(client.MultiplexerModel);
        model.* = .init(allocator);
        defer allocator.destroy(model);
        defer model.deinit();

        const location: core.TabLocation = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(1) };
        for (0..count) |index| {
            try model.addDiscovered(.{ .pane_id = @enumFromInt(index + 1), .location = location, .area = .{ .w = 1, .h = 1 } });
        }

        try writer.print("{{\"type\":\"live_storage\",\"panes\":{d},\"cell_size\":\"1x1\",\"bytes\":{d},\"allocations\":{d}}}\n", .{ count, accounting.allocated_bytes - accounting.freed_bytes, accounting.allocations - accounting.deallocations });
    }
}
