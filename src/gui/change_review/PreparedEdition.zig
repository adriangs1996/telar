//! Worker-owned immutable diff index. Visible source lives until its slot retires.
const syntaxhl = @import("syntaxhl");
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Highlighter = @import("../syntax/DiffHighlighter.zig");
const Self = @This();

generation: u64 = 0,
edition: u64 = 0,
source: [core.change_review.max_patch_bytes]u8 = undefined,
len: usize = 0,
revision: client.ChangeReviewRevision = .{},
roles: [core.change_review.max_patch_bytes]syntaxhl.Role = undefined,
failure: ?anyerror = null,
/// The highlighting budget this edition stopped at; the rows past it stay
/// plain and the edition is still reviewable.
syntax_limit: ?core.Limit = null,

/// Runs only in the observation worker, never while forwarding native input.
/// Example: `prepared.build(.{ .allocator = allocator, .io = io });`
pub fn build(self: *Self, context: struct { allocator: std.mem.Allocator, io: std.Io }) void {
    self.failure = null;
    self.syntax_limit = null;
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
        .partial = true,
    };
    highlighter.run() catch |err| {
        self.failure = err;
        return;
    };

    self.syntax_limit = highlighter.limited;
}
