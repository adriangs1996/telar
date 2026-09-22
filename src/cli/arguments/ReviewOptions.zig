const core = @import("telar-core");
const std = @import("std");
const Cursor = @import("Cursor.zig");
const values = @import("values.zig");
const ReviewOptions = @This();

pub const Action = enum { list, show, comment, delete, submit, reviewed, feedback, ack };

action: Action,
target: values.Target = .current,
socket: ?[*:0]const u8 = null,
edition: u64 = 0,
expected_revision: ?u64 = null,
comment_id: u64 = 0,
path: []const u8 = "",
first_line: u32 = 0,
last_line: u32 = 0,
body: []const u8 = "",
side: core.change_review.Side = .after,
draft: bool = false,
reviewed: bool = true,
provider: core.AgentProvider = .unknown,
session: []const u8 = "",
feedback_id: u64 = 0,
json: bool = false,

/// Parses explicit review actions without connecting or modifying any files.
/// Example: `const options = try ReviewOptions.parse(&.{ "show", "--current" });`
pub fn parse(args: []const [*:0]const u8) !ReviewOptions {
    if (args.len == 0) {
        return error.MissingReviewAction;
    }

    const action = std.meta.stringToEnum(Action, std.mem.span(args[0])) orelse return error.UnknownReviewAction;
    var self: ReviewOptions = .{ .action = action };
    var cursor: Cursor = .{ .remaining = args[1..] };
    if (cursor.remaining.len != 0 and (!std.mem.startsWith(u8, std.mem.span(cursor.remaining[0]), "--") or std.mem.eql(u8, std.mem.span(cursor.remaining[0]), "--current"))) {
        self.target = values.Target.parse(cursor.next().?);
        if (self.target == .name) {
            return error.InvalidPaneId;
        }
    }

    var seen = std.EnumSet(Option).initEmpty();
    while (cursor.next()) |argument| {
        const text = std.mem.span(argument);
        if (!std.mem.startsWith(u8, text, "--")) {
            return error.UnknownReviewOption;
        }

        const option = optionName(text[2..]) orelse return error.UnknownReviewOption;
        if (seen.contains(option)) {
            return error.DuplicateReviewOption;
        }

        seen.insert(option);
        switch (option) {
            .json => self.json = true,
            .draft => self.draft = true,
            .before => self.side = .before,
            .unreviewed => self.reviewed = false,
            else => {
                const value = try cursor.require(error.MissingReviewOptionValue);
                const bytes = std.mem.span(value);
                switch (option) {
                    .socket => self.socket = value,
                    .edition => self.edition = try positive(u64, bytes),
                    .revision => self.expected_revision = try positive(u64, bytes),
                    .comment_id => self.comment_id = try positive(u64, bytes),
                    .file => self.path = bytes,
                    .first => self.first_line = try positive(u32, bytes),
                    .last => self.last_line = try positive(u32, bytes),
                    .body => self.body = bytes,
                    .provider => self.provider = std.meta.stringToEnum(core.AgentProvider, bytes) orelse return error.InvalidReviewProvider,
                    .session => self.session = bytes,
                    .feedback_id => self.feedback_id = try positive(u64, bytes),
                    else => unreachable,
                }
            },
        }
    }

    try self.validate();
    return self;
}

const Option = enum { socket, edition, revision, comment_id, file, first, last, body, provider, session, feedback_id, json, draft, before, unreviewed };

fn optionName(name: []const u8) ?Option {
    if (std.mem.eql(u8, name, "comment-id")) {
        return .comment_id;
    }

    if (std.mem.eql(u8, name, "feedback-id")) {
        return .feedback_id;
    }

    return std.meta.stringToEnum(Option, name);
}

fn positive(comptime T: type, bytes: []const u8) !T {
    const number = std.fmt.parseUnsigned(T, bytes, 10) catch return error.InvalidReviewNumber;
    if (number == 0) {
        return error.InvalidReviewNumber;
    }

    return number;
}

fn validate(self: *ReviewOptions) !void {
    if (self.session.len > core.change_review.max_identity_bytes or !std.unicode.utf8ValidateSlice(self.session)) {
        return error.InvalidReviewSession;
    }

    if (self.action == .comment) {
        if (self.last_line == 0) {
            self.last_line = self.first_line;
        }

        if (self.path.len == 0 or self.path.len > core.change_review.max_path_bytes or self.first_line == 0 or self.last_line < self.first_line or self.body.len == 0 or self.body.len > core.change_review.max_comment_bytes or !std.unicode.utf8ValidateSlice(self.body)) {
            return error.InvalidReviewComment;
        }
    } else if (self.body.len != 0 or self.path.len != 0 or self.first_line != 0 or self.last_line != 0 or self.draft or self.side == .before) {
        return error.UnknownReviewOption;
    }

    if (self.action == .delete and self.comment_id == 0) {
        return error.MissingReviewCommentId;
    }

    if (self.comment_id != 0 and self.action != .comment and self.action != .delete) {
        return error.UnknownReviewOption;
    }

    if (!self.reviewed and self.action != .reviewed) {
        return error.UnknownReviewOption;
    }

    if (self.action == .feedback or self.action == .ack) {
        if (self.provider == .unknown or self.session.len == 0 or self.session.len > core.change_review.max_identity_bytes) {
            return error.MissingReviewAgentIdentity;
        }

        if (self.action == .ack and self.feedback_id == 0) {
            return error.MissingReviewFeedbackId;
        }
    } else if (self.provider != .unknown or self.feedback_id != 0) {
        return error.UnknownReviewOption;
    }
}

test "review CLI parses line ranges and requires cooperative feedback identity" {
    const options = try ReviewOptions.parse(&.{ "comment", "--current", "--edition", "3", "--file", "src/main.zig", "--first", "7", "--last", "9", "--body", "Keep café intact", "--before" });
    try std.testing.expectEqual(@as(u64, 3), options.edition);
    try std.testing.expectEqual(@as(u32, 9), options.last_line);
    try std.testing.expectEqual(core.change_review.Side.before, options.side);
    const feedback = try ReviewOptions.parse(&.{ "feedback", "--provider", "codex", "--session", "session-1", "--json" });
    try std.testing.expectEqual(core.AgentProvider.codex, feedback.provider);
    const pinned = try ReviewOptions.parse(&.{ "reviewed", "--edition", "3", "--session", "session-1" });
    try std.testing.expectEqualStrings("session-1", pinned.session);
    try std.testing.expectError(error.MissingReviewAgentIdentity, ReviewOptions.parse(&.{"feedback"}));
    try std.testing.expectError(error.MissingReviewFeedbackId, ReviewOptions.parse(&.{ "ack", "--provider", "codex", "--session", "session-1" }));
    try std.testing.expectError(error.InvalidReviewComment, ReviewOptions.parse(&.{ "comment", "--file", "main.zig", "--first", "9", "--last", "2", "--body", "backwards" }));
    try std.testing.expectError(error.DuplicateReviewOption, ReviewOptions.parse(&.{ "show", "--edition", "2", "--edition", "3" }));
}
