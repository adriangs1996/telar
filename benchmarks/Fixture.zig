const core = @import("telar-core");
const std = @import("std");
const main = @import("main.zig");
const Fixture = @This();

gpa: std.mem.Allocator,
cells_a: []core.Cell,
cells_b: []core.Cell,
encode_buffer: []u8,
terminal_output: []u8,
sparse_storage_a: []u8,
sparse_storage_b: []u8,
fragmented_storage_a: []u8,
fragmented_storage_b: []u8,
full_storage_a: []u8,
full_storage_b: []u8,
sparse_spans: [2][1]core.Span,
fragmented_spans: [2][]core.Span,
full_spans: [2][1]core.Span,
sparse_payloads: [2][]const u8,
fragmented_payloads: [2][]const u8,
full_payloads: [2][]const u8,

pub fn init(gpa: std.mem.Allocator) !Fixture {
    const cells_a = try gpa.alloc(core.Cell, main.cell_count);
    errdefer gpa.free(cells_a);
    const cells_b = try gpa.alloc(core.Cell, main.cell_count);
    errdefer gpa.free(cells_b);
    main.fillEditor(cells_a, 0);
    main.fillEditor(cells_b, 1);

    const encode_buffer = try gpa.alloc(u8, core.max_frame_size);
    errdefer gpa.free(encode_buffer);
    const terminal_output = try gpa.alloc(u8, core.max_frame_size);
    errdefer gpa.free(terminal_output);
    const sparse_storage_a = try gpa.alloc(u8, core.max_frame_size);
    errdefer gpa.free(sparse_storage_a);
    const sparse_storage_b = try gpa.alloc(u8, core.max_frame_size);
    errdefer gpa.free(sparse_storage_b);
    const fragmented_storage_a = try gpa.alloc(u8, core.max_frame_size);
    errdefer gpa.free(fragmented_storage_a);
    const fragmented_storage_b = try gpa.alloc(u8, core.max_frame_size);
    errdefer gpa.free(fragmented_storage_b);
    const full_storage_a = try gpa.alloc(u8, core.max_frame_size);
    errdefer gpa.free(full_storage_a);
    const full_storage_b = try gpa.alloc(u8, core.max_frame_size);
    errdefer gpa.free(full_storage_b);

    const middle: u32 = @intCast(main.cell_count / 2);
    const sparse_spans = [2][1]core.Span{
        .{.{ .start = middle, .cells = cells_a[middle..][0..1] }},
        .{.{ .start = middle, .cells = cells_b[middle..][0..1] }},
    };
    const fragmented_a = try gpa.alloc(core.Span, main.fragmented_span_count);
    errdefer gpa.free(fragmented_a);
    const fragmented_b = try gpa.alloc(core.Span, main.fragmented_span_count);
    errdefer gpa.free(fragmented_b);
    main.fillFragmentedSpans(fragmented_a, cells_a);
    main.fillFragmentedSpans(fragmented_b, cells_b);
    const full_spans = [2][1]core.Span{
        .{.{ .start = 0, .cells = cells_a }},
        .{.{ .start = 0, .cells = cells_b }},
    };

    const sparse_payload_a = try core.encodePaneFrame(sparse_storage_a, main.frame(2, &sparse_spans[0]));
    const sparse_payload_b = try core.encodePaneFrame(sparse_storage_b, main.frame(3, &sparse_spans[1]));
    const fragmented_payload_a = try core.encodePaneFrame(fragmented_storage_a, main.frame(2, fragmented_a));
    const fragmented_payload_b = try core.encodePaneFrame(fragmented_storage_b, main.frame(3, fragmented_b));
    const full_payload_a = try core.encodePaneFrame(full_storage_a, main.frame(2, &full_spans[0]));
    const full_payload_b = try core.encodePaneFrame(full_storage_b, main.frame(3, &full_spans[1]));

    return .{
        .gpa = gpa,
        .cells_a = cells_a,
        .cells_b = cells_b,
        .encode_buffer = encode_buffer,
        .terminal_output = terminal_output,
        .sparse_storage_a = sparse_storage_a,
        .sparse_storage_b = sparse_storage_b,
        .fragmented_storage_a = fragmented_storage_a,
        .fragmented_storage_b = fragmented_storage_b,
        .full_storage_a = full_storage_a,
        .full_storage_b = full_storage_b,
        .sparse_spans = sparse_spans,
        .fragmented_spans = .{ fragmented_a, fragmented_b },
        .full_spans = full_spans,
        .sparse_payloads = .{ sparse_payload_a, sparse_payload_b },
        .fragmented_payloads = .{ fragmented_payload_a, fragmented_payload_b },
        .full_payloads = .{ full_payload_a, full_payload_b },
    };
}

pub fn deinit(self: *Fixture) void {
    self.gpa.free(self.fragmented_spans[1]);
    self.gpa.free(self.fragmented_spans[0]);
    self.gpa.free(self.full_storage_b);
    self.gpa.free(self.full_storage_a);
    self.gpa.free(self.fragmented_storage_b);
    self.gpa.free(self.fragmented_storage_a);
    self.gpa.free(self.sparse_storage_b);
    self.gpa.free(self.sparse_storage_a);
    self.gpa.free(self.terminal_output);
    self.gpa.free(self.encode_buffer);
    self.gpa.free(self.cells_b);
    self.gpa.free(self.cells_a);
}

pub fn spans(self: *const Fixture, workload: main.Workload, variant: usize) []const core.Span {
    return switch (workload) {
        .one_cell => &self.sparse_spans[variant],
        .fragmented => self.fragmented_spans[variant],
        .full_screen => &self.full_spans[variant],
    };
}

pub fn payloads(self: *const Fixture, workload: main.Workload) [2][]const u8 {
    return switch (workload) {
        .one_cell => self.sparse_payloads,
        .fragmented => self.fragmented_payloads,
        .full_screen => self.full_payloads,
    };
}
