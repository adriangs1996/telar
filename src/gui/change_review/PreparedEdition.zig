//! Worker-owned immutable diff index. Visible source lives until its slot retires.
const syntaxhl = @import("syntaxhl");
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Highlighter = @import("../syntax/DiffHighlighter.zig");
const syntax_limits = @import("../syntax/limits.zig");
const Self = @This();

const log = std.log.scoped(.change_review);

generation: u64 = 0,
edition: u64 = 0,
/// `core.change_review.max_patch_bytes` long, reserved once by `init`.
source: []u8 = &.{},
len: usize = 0,
revision: client.ChangeReviewRevision = .{},
/// One role per source byte, as long as `source`. What a highlighting job
/// did not reach stays plain.
roles: []syntaxhl.Role = &.{},
failure: ?anyerror = null,
/// The highlighting limit the last build reached; the adapter loop reports
/// it when it adopts the edition.
limit: ?core.LimitReach = null,

/// Reserves the slot's source and roles once, when the review panel is
/// created, so neither preparing nor painting an edition allocates.
///
/// ```zig
/// var slot = try PreparedEdition.init(allocator);
/// defer slot.deinit(allocator);
/// ```
pub fn init(allocator: std.mem.Allocator) !Self {
    const source = try allocator.alloc(u8, core.change_review.max_patch_bytes);
    errdefer allocator.free(source);

    const roles = try allocator.alloc(syntaxhl.Role, core.change_review.max_patch_bytes);
    return .{
        .source = source,
        .roles = roles,
    };
}

/// Frees what `init` reserved. Example: `slot.deinit(allocator);`
pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.roles);
    allocator.free(self.source);
    self.* = .{};
}

/// Runs only in the observation worker, never while forwarding native input.
/// Highlighting never refuses an edition: a job that reaches a limit keeps
/// what it colored and records the limit in `limit`, and one that fails
/// leaves the whole edition plain. `job_ms` defaults to the job's budget;
/// tests shrink it.
///
/// ```zig
/// prepared.build(.{ .allocator = allocator, .io = io });
/// ```
pub fn build(self: *Self, context: struct { allocator: std.mem.Allocator, io: std.Io, job_ms: i64 = syntax_limits.job_ms }) void {
    self.failure = null;
    self.limit = null;
    self.revision.load(self.source[0..self.len]) catch |err| {
        self.failure = err;
        return;
    };

    self.revision.ensureReviewable() catch |err| {
        self.failure = err;
        return;
    };

    var highlighter: Highlighter = .{
        .allocator = context.allocator,
        .io = context.io,
        .text = self.source[0..self.len],
        .roles = self.roles[0..self.len],
        .job_ms = context.job_ms,
    };

    self.limit = highlighter.run() catch |err| {
        @memset(self.roles[0..self.len], .plain);
        log.warn("syntax highlighting failed; the edition shows plain text: {s}", .{@errorName(err)});
        return;
    };
}
