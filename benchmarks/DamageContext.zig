const DamageContext = @This();
const std = @import("std");
const core = @import("telar-core");
const source_namespace = @import("main.zig");
const Fixture = @import("Fixture.zig");
gpa: std.mem.Allocator,
acknowledged: []core.ui.Cell,
current: []core.ui.Cell,
damaged_rows: []bool,
spans: []source_namespace.schema.frame.Span,
changed_index: usize,

fn init(gpa: std.mem.Allocator, fixture: *const Fixture, workload: source_namespace.Workload) !DamageContext {
    const acknowledged = try gpa.dupe(core.ui.Cell, fixture.cells_a);
    errdefer gpa.free(acknowledged);
    const current = try gpa.dupe(core.ui.Cell, fixture.cells_a);
    errdefer gpa.free(current);
    const damaged_rows = try gpa.alloc(bool, source_namespace.rows);
    errdefer gpa.free(damaged_rows);
    @memset(damaged_rows, false);
    if (workload == .full_screen) {
        @memcpy(current, fixture.cells_b);
        @memset(damaged_rows, true);
    } else {
        for (fixture.spans(workload, 1)) |span| {
            const start: usize = @intCast(span.start);
            @memcpy(current[start..][0..span.cells.len], span.cells);
            damaged_rows[start / source_namespace.cols] = true;
        }
    }
    const changed_index: usize = @intCast(fixture.spans(workload, 1)[0].start);
    const spans = try gpa.alloc(source_namespace.schema.frame.Span, source_namespace.schema.frame.max_span_count);
    return .{
        .gpa = gpa,
        .acknowledged = acknowledged,
        .current = current,
        .damaged_rows = damaged_rows,
        .spans = spans,
        .changed_index = changed_index,
    };
}

fn deinit(context: *DamageContext) void {
    context.gpa.free(context.spans);
    context.gpa.free(context.damaged_rows);
    context.gpa.free(context.current);
    context.gpa.free(context.acknowledged);
}
