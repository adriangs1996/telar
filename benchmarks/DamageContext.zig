const std = @import("std");
const CellType = @import("telar-core").Cell;
const SpanType = @import("telar-core").Span;
const Fixture = @import("Fixture.zig");
const main = @import("main.zig");
const max_span_count_module = @import("telar-core").max_span_count;
const DamageContext = @This();

gpa: std.mem.Allocator,
acknowledged: []CellType,
current: []CellType,
damaged_rows: []bool,
spans: []SpanType,
changed_index: usize,

pub fn init(gpa: std.mem.Allocator, fixture: *const Fixture, workload: main.Workload) !DamageContext {
    const acknowledged = try gpa.dupe(CellType, fixture.cells_a);
    errdefer gpa.free(acknowledged);
    const current = try gpa.dupe(CellType, fixture.cells_a);
    errdefer gpa.free(current);
    const damaged_rows = try gpa.alloc(bool, main.rows);
    errdefer gpa.free(damaged_rows);
    @memset(damaged_rows, false);
    if (workload == .full_screen) {
        @memcpy(current, fixture.cells_b);
        @memset(damaged_rows, true);
    } else {
        for (fixture.spans(workload, 1)) |span| {
            const start: usize = @intCast(span.start);
            @memcpy(current[start..][0..span.cells.len], span.cells);
            damaged_rows[start / main.cols] = true;
        }
    }
    const changed_index: usize = @intCast(fixture.spans(workload, 1)[0].start);
    const spans = try gpa.alloc(SpanType, max_span_count_module);
    return .{
        .gpa = gpa,
        .acknowledged = acknowledged,
        .current = current,
        .damaged_rows = damaged_rows,
        .spans = spans,
        .changed_index = changed_index,
    };
}

pub fn deinit(context: *DamageContext) void {
    context.gpa.free(context.spans);
    context.gpa.free(context.damaged_rows);
    context.gpa.free(context.current);
    context.gpa.free(context.acknowledged);
}
