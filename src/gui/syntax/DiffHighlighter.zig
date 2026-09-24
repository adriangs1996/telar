//! Called only by the observation worker. Rendering consumes retained roles.
const syntaxhl = @import("syntaxhl");
const core = @import("telar-core");
const std = @import("std");
const client = @import("telar-client");
const SourceSide = @import("SourceSide.zig");
const captures = syntaxhl.captures;
const limits = @import("limits.zig");
const Self = @This();

const Status = enum(u32) { ok, invalid, unsupported, limit, cancelled, internal };
extern fn telar_syntax_highlight(request: *NativeRequest) u32;
extern fn telar_syntax_prepare(language: [*:0]const u8) u32;

allocator: std.mem.Allocator,
io: std.Io,
text: []const u8,
roles: []syntaxhl.Role,
spans: []CapturedSpan = &.{},
language: syntaxhl.language.Language = .plain,
started: std.Io.Timestamp = .{ .nanoseconds = 0 },
fragments: usize = 0,

/// Highlights each before/after hunk with bundled upstream grammars and queries.
/// Missing lines are never invented; full-file review snapshots can use the
/// same FFI directly instead. Example: `try worker.run();`
pub fn run(self: *Self) !void {
    if (self.text.len > syntaxhl.limits.source_bytes or self.roles.len != self.text.len) {
        return error.SyntaxLimit;
    }

    @memset(self.roles, .plain);
    try self.prepareLanguages();
    self.started = std.Io.Clock.awake.now(self.io);
    self.spans = try self.allocator.alloc(CapturedSpan, syntaxhl.limits.source_bytes);
    defer self.allocator.free(self.spans);
    var before: SourceSide = .{ .allocator = self.allocator, .origin = @intFromPtr(self.text.ptr), .old = true };
    defer before.deinit();
    var after: SourceSide = .{ .allocator = self.allocator, .origin = @intFromPtr(self.text.ptr), .old = false };
    defer after.deinit();
    var lines: core.ChangeReviewDiffLines = .{ .text = self.text };
    while (lines.next()) |line| {
        switch (line.kind) {
            .file, .hunk => {
                try self.highlight(&before);
                try self.highlight(&after);
                before.clear();
                after.clear();
                if (line.kind == .file) {
                    self.language = syntaxhl.language.fromPath(line.text);
                }
            },
            .removed => try before.append(line),
            .added => try after.append(line),
            .context => {
                try before.append(line);
                try after.append(line);
            },
            .metadata => {},
        }
    }

    try self.highlight(&before);
    try self.highlight(&after);
}

// Upstream query compilation depends only on bundled grammars. Keep this cold
// setup outside the deadline for processing untrusted source fragments.
fn prepareLanguages(self: *Self) !void {
    var lines: core.ChangeReviewDiffLines = .{ .text = self.text };
    while (lines.next()) |line| {
        if (line.kind != .file) {
            continue;
        }

        const language = syntaxhl.language.fromPath(line.text);
        if (language == .plain) {
            continue;
        }

        const status = std.enums.fromInt(Status, telar_syntax_prepare(@tagName(language))) orelse return error.InvalidSyntaxResult;
        if (status != .ok) {
            return error.SyntaxUnavailable;
        }
    }
}

fn highlight(self: *Self, side: *const SourceSide) !void {
    if (self.language == .plain or side.source.items.len == 0) {
        return;
    }

    self.fragments += 1;
    const elapsed = self.started.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds();
    if (self.fragments > limits.fragments or elapsed > limits.job_ms) {
        return error.SyntaxLimit;
    }

    var request: NativeRequest = .{ .language = @tagName(self.language), .source = side.source.items.ptr, .source_len = side.source.items.len, .spans = self.spans.ptr, .capacity = self.spans.len };
    const status = std.enums.fromInt(Status, telar_syntax_highlight(&request)) orelse return error.InvalidSyntaxResult;
    if (status != .ok or request.count > self.spans.len) {
        return error.SyntaxUnavailable;
    }

    var mapping_index: usize = 0;
    var end: usize = 0;
    for (self.spans[0..request.count]) |span| {
        if (span.start != end or span.end <= span.start or span.end > side.source.items.len) {
            return error.InvalidSyntaxResult;
        }

        end = span.end;
        const role = captures.role(std.mem.span(span.capture));
        while (mapping_index < side.mappings.items.len and side.mappings.items[mapping_index].source_start + side.mappings.items[mapping_index].len <= span.start) {
            mapping_index += 1;
        }

        var index = mapping_index;
        while (index < side.mappings.items.len) : (index += 1) {
            const mapping = side.mappings.items[index];
            if (mapping.source_start >= span.end) {
                break;
            }

            if (mapping.apply) {
                const first = @max(mapping.source_start, span.start) - mapping.source_start;
                const last = @min(mapping.source_start + mapping.len, span.end) - mapping.source_start;
                @memset(self.roles[mapping.diff_start + first .. mapping.diff_start + last], role);
            }
        }
    }

    if (end != side.source.items.len) {
        return error.InvalidSyntaxResult;
    }
}

const NativeRequest = extern struct {
    language: [*:0]const u8,
    source: [*]const u8,
    source_len: usize,
    spans: [*]CapturedSpan,
    capacity: usize,
    count: usize = 0,
};

const CapturedSpan = extern struct {
    start: u32,
    end: u32,
    capture: [*:0]const u8,
};
