//! Checked, bounded review controls and immutable edition snapshots.
const bytecodec = @import("bytecodec");
const std = @import("std");
const Encoder = bytecodec.Encoder;
const Decoder = bytecodec.Decoder;
const id = @import("../id.zig");
const codec = @import("../codec.zig");
const tags = @import("tags.zig");
const limits = @import("../../change_review.zig");
const Query = @import("QueryChangeReview.zig");
const Command = @import("ChangeReviewCommand.zig");
const Sample = @import("ReportChangeReviewSample.zig");
const Snapshot = @import("ChangeReviewSnapshotView.zig");
const Changed = @import("ChangeReviewChanged.zig");
const Comment = @import("../../ChangeReviewComment.zig");

pub fn encodeQueryChangeReview(buffer: []u8, value: Query) ![]const u8 {
    return encode(buffer, value, @intFromEnum(tags.ClientTag.query_change_review));
}

pub fn encodeChangeReviewCommand(buffer: []u8, value: Command) ![]const u8 {
    return encode(buffer, value, @intFromEnum(tags.ClientTag.change_review_command));
}

pub fn encodeReportChangeReviewSample(buffer: []u8, value: Sample) ![]const u8 {
    return encode(buffer, value, @intFromEnum(tags.ClientTag.report_change_review_sample));
}

pub fn encodeChangeReviewSnapshot(buffer: []u8, value: Snapshot) ![]const u8 {
    return encode(buffer, value, @intFromEnum(tags.ServerTag.change_review_snapshot));
}

/// Announces newly captured editions without replacing a displayed review.
/// Example: `const bytes = try encodeChangeReviewChanged(buffer, changed);`
pub fn encodeChangeReviewChanged(buffer: []u8, value: Changed) ![]const u8 {
    return encode(buffer, value, @intFromEnum(tags.ServerTag.change_review_changed));
}

fn encode(buffer: []u8, value: anytype, tag: u8) ![]const u8 {
    try validate(value);
    var encoder = Encoder.init(buffer);
    try encoder.writeByte(tag);
    try write(&encoder, value);
    return encoder.finish();
}

/// Decodes only after the containing frame has passed the transport byte limit.
/// Example: `const command = try review.decode(Command, decoder);`.
pub fn decode(comptime T: type, decoder: *Decoder) !T {
    const value = try read(T, decoder);
    try validate(value);
    return value;
}

fn write(encoder: *Encoder, value: anytype) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .@"struct" => inline for (@typeInfo(T).@"struct".fields) |field| {
            if (comptime T == Snapshot and std.mem.eql(u8, field.name, "comment_storage")) {
                try encoder.writeByte(value.comment_count);
                for (value.comments()) |comment| {
                    try write(encoder, comment);
                }
            } else if (comptime !(T == Snapshot and std.mem.eql(u8, field.name, "comment_count"))) {
                try write(encoder, @field(value, field.name));
            }
        },
        .@"enum" => try encoder.writeInt(@typeInfo(T).@"enum".tag_type, @intFromEnum(value)),
        .int => try encoder.writeInt(T, value),
        .bool => try encoder.writeByte(@intFromBool(value)),
        .pointer => try encoder.writeSized32(value),
        else => @compileError("unsupported review value"),
    }
}

fn read(comptime T: type, decoder: *Decoder) !T {
    return switch (@typeInfo(T)) {
        .@"struct" => blk: {
            var value: T = undefined;
            inline for (@typeInfo(T).@"struct".fields) |field| {
                if (comptime T == Snapshot and std.mem.eql(u8, field.name, "comment_storage")) {
                    value.comment_count = try decoder.readByte();
                    if (value.comment_count > limits.max_comments) {
                        return error.InvalidChangeReview;
                    }
                    value.comment_storage = @splat(.{});
                    for (value.comment_storage[0..value.comment_count]) |*comment| {
                        comment.* = try read(Comment, decoder);
                    }
                } else if (comptime !(T == Snapshot and std.mem.eql(u8, field.name, "comment_count"))) {
                    @field(value, field.name) = try read(field.type, decoder);
                }
            }
            break :blk value;
        },
        .@"enum" => blk: {
            const raw = try decoder.readInt(@typeInfo(T).@"enum".tag_type);
            if (T == id.RequestId or T == id.PaneId) {
                break :blk @enumFromInt(raw);
            }
            break :blk std.enums.fromInt(T, raw) orelse return error.InvalidChangeReview;
        },
        .int => try decoder.readInt(T),
        .bool => try decoder.readBool(),
        .pointer => try decoder.readSized32(),
        else => @compileError("unsupported review value"),
    };
}

pub fn validate(value: anytype) !void {
    const T = @TypeOf(value);
    if (T != Changed) {
        try codec.validateRequestId(value.request_id);
    }
    try codec.validatePaneId(value.pane_id);
    if (value.pane_generation == 0) {
        return error.InvalidPaneGeneration;
    }
    try text(value.session, limits.max_identity_bytes);
    if (T == Changed and value.session.len == 0) {
        return error.InvalidChangeReview;
    }
    if (T == Command) {
        try text(value.path, limits.max_path_bytes);
        try text(value.body, limits.max_comment_bytes);
        try text(value.session, limits.max_identity_bytes);
        if (value.action == .save_comment and (value.path.len == 0 or value.first_line == 0 or value.last_line < value.first_line)) {
            return error.InvalidChangeReview;
        }
    } else if (T == Sample) {
        try text(value.path, limits.max_path_bytes);
        try text(value.content, limits.max_sample_bytes);
        try text(value.session, limits.max_identity_bytes);
        try text(value.tool_call_id, limits.max_identity_bytes);
        if (value.path.len == 0 or value.session.len == 0 or value.tool_call_id.len == 0 or value.provider == .unknown or (!value.exists and value.content.len != 0)) {
            return error.InvalidChangeReview;
        }
    } else if (T == Snapshot) {
        try text(value.patch, limits.max_patch_bytes);
        try text(value.feedback, limits.max_feedback_bytes);
        try text(value.status, 512);
        if (value.comment_count > limits.max_comments) {
            return error.InvalidChangeReview;
        }
        for (value.comments(), 0..) |comment, index| {
            try text(comment.path, limits.max_path_bytes);
            try text(comment.body, limits.max_comment_bytes);
            if (comment.id == 0 or comment.first_line == 0 or comment.last_line < comment.first_line) {
                return error.InvalidChangeReview;
            }
            for (value.comments()[0..index]) |prior| {
                if (prior.id == comment.id) {
                    return error.InvalidChangeReview;
                }
            }
        }
    }
}

fn text(value: []const u8, maximum: usize) !void {
    if (value.len > maximum or !std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null) {
        return error.InvalidChangeReview;
    }
}

test "change review wire rejects malformed bounds and roundtrips range comments" {
    var buffer: [128 * 1024]u8 = undefined;
    const command: Command = .{ .request_id = @enumFromInt(1), .pane_id = @enumFromInt(2), .pane_generation = 3, .edition_id = 4, .expected_revision = 5, .action = .save_comment, .path = "src/main.zig", .first_line = 10, .last_line = 12, .body = "Keep the entire range." };
    const bytes = try encodeChangeReviewCommand(&buffer, command);
    var decoder = Decoder.init(bytes[1..]);
    const decoded = try decode(Command, &decoder);
    try std.testing.expectEqualStrings(command.body, decoded.body);
    try std.testing.expectEqual(command.last_line, decoded.last_line);
    var invalid = command;
    invalid.last_line = 9;
    try std.testing.expectError(error.InvalidChangeReview, encodeChangeReviewCommand(&buffer, invalid));
}

test "change review invalidation carries the provider conversation and rejects unbounded identities" {
    var bytes: [512]u8 = undefined;
    var changed: Changed = .{ .pane_id = @enumFromInt(2), .pane_generation = 3, .session = "thread-A", .latest_edition_id = 4 };
    const encoded = try encodeChangeReviewChanged(&bytes, changed);
    try std.testing.expectEqual(@intFromEnum(tags.ServerTag.change_review_changed), encoded[0]);
    var decoder = Decoder.init(encoded[1..]);
    const result = try decode(Changed, &decoder);
    try std.testing.expectEqualStrings("thread-A", result.session);
    try std.testing.expectEqual(@as(u64, 4), result.latest_edition_id);
    var long: [limits.max_identity_bytes + 1]u8 = @splat('a');
    changed.session = &long;
    try std.testing.expectError(error.InvalidChangeReview, encodeChangeReviewChanged(&bytes, changed));
}
