const std = @import("std");
const Widget = @import("../../change_review/Widget.zig");
const LiveBridge = @import("LiveBridge.zig");
const LiveSnapshot = @import("LiveSnapshot.zig");
const LiveResponse = @import("LiveResponse.zig");
const ReviewFeedback = @import("ReviewFeedback.zig");
const live_review = @import("live_review.zig");

const initial_patch = "Updated sample.txt\n@@ -20,3 +30,3 @@\n-old first\n+new first\n-old second\n+new second\n context\n@@ -50 +60 @@\n-old later\n+new later\nUpdated other.txt\n@@ -1 +1 @@\n-before\n+after\n";
const corrected_patch = "Updated sample.txt\n@@ -30,3 +30,4 @@\n new first\n-new second\n+corrected second\n+inserted\n context\n";

fn parse(value: LiveResponse) !*LiveSnapshot {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try std.json.Stringify.value(value, .{}, &bytes.writer);
    return LiveSnapshot.parse(std.testing.io, std.testing.allocator, bytes.written());
}

fn widgetFrom(snapshot: *LiveSnapshot) !*Widget {
    const widget = try std.testing.allocator.create(Widget);
    errdefer std.testing.allocator.destroy(widget);
    widget.* = .{};
    try live_review.load(widget, snapshot);
    return widget;
}

test "review prototype live reload resolves side coordinates and rejects nonexistent or cross-hunk comments" {
    const good = try parse(.{
        .schema = 1,
        .session_id = "session-a",
        .revisions = &.{.{ .id = "edition-a", .patch = initial_patch }},
        .comments = &.{
            .{ .file = "sample.txt", .side = .after, .first_line = 30, .last_line = 31, .body = "Check café\nSecond line" },
            .{ .file = "sample.txt", .side = .before, .first_line = 20, .last_line = 21, .body = "Retain the old behavior" },
        },
        .status = .reviewable,
    });
    defer good.deinit();
    const widget = try widgetFrom(good);
    defer std.testing.allocator.destroy(widget);
    const after = widget.model.comments[0];
    try std.testing.expectEqual(@as(usize, 1), after.anchor.first);
    try std.testing.expectEqual(@as(usize, 3), after.anchor.last);
    try std.testing.expect(!after.anchor.before);
    try std.testing.expect(!after.draft);
    try std.testing.expectEqualStrings("Check café\nSecond line", after.body.text());
    const before = widget.model.comments[1];
    try std.testing.expectEqual(@as(usize, 0), before.anchor.first);
    try std.testing.expectEqual(@as(usize, 2), before.anchor.last);
    try std.testing.expect(before.anchor.before);

    const invalid = [_]ReviewFeedback{
        .{ .file = "missing.txt", .side = .after, .first_line = 30, .last_line = 31, .body = "Unknown path" },
        .{ .file = "sample.txt", .side = .after, .first_line = 29, .last_line = 31, .body = "Unknown first line" },
        .{ .file = "sample.txt", .side = .after, .first_line = 30, .last_line = 99, .body = "Unknown last line" },
        .{ .file = "sample.txt", .side = .before, .first_line = 30, .last_line = 31, .body = "Wrong side" },
        .{ .file = "sample.txt", .side = .after, .first_line = 30, .last_line = 60, .body = "Crosses hunk boundary" },
    };
    for (invalid) |comment| {
        const snapshot = try parse(.{ .schema = 1, .session_id = "session-a", .revisions = &.{.{ .id = "edition-a", .patch = initial_patch }}, .comments = &.{comment}, .status = .reviewable });
        defer snapshot.deinit();
        try std.testing.expectError(error.InvalidReviewComment, live_review.load(widget, snapshot));
        try std.testing.expectEqualStrings("Check café\nSecond line", widget.model.comments[0].body.text());
        try std.testing.expectEqualDeep(after.anchor, widget.model.comments[0].anchor);
    }
}

test "review prototype correction arrives without replacing the active edition editor or anchored draft" {
    const initial = try parse(.{ .schema = 1, .session_id = "session-a", .revisions = &.{.{ .id = "edition-a", .patch = initial_patch }}, .status = .reviewable });
    defer initial.deinit();
    const corrected = try parse(.{ .schema = 1, .session_id = "session-a", .revisions = &.{ .{ .id = "edition-a", .patch = initial_patch }, .{ .id = "edition-b", .patch = corrected_patch } }, .status = .complete });
    defer corrected.deinit();
    const widget = try widgetFrom(initial);
    defer std.testing.allocator.destroy(widget);
    widget.delivery = .sending;
    widget.model.select(.{ .row = 1, .extend = false });
    widget.model.select(.{ .row = 3, .extend = true });
    widget.model.comment();
    const index = widget.model.editing.?;
    const anchor = widget.model.comments[index].anchor;
    _ = widget.model.comments[index].body.replace(.{ 0, 0 }, "Unsent café\nContinue writing here");
    widget.generation = 17;
    widget.text_revision = 29;
    widget.scroll = 142;
    widget.copy_range = .{ 5, 12 };

    try live_review.accept(widget, .{ .initial = initial, .corrected = corrected });
    try std.testing.expectEqual(@as(usize, 0), widget.model.revision);
    try std.testing.expectEqual(@as(usize, 0), widget.model.file);
    try std.testing.expectEqual(@as(usize, 3), widget.model.head);
    try std.testing.expectEqual(@as(usize, 1), widget.model.tail);
    try std.testing.expectEqual(index, widget.model.editing.?);
    try std.testing.expectEqual(index, widget.model.expanded.?);
    try std.testing.expectEqualDeep(anchor, widget.model.comments[index].anchor);
    try std.testing.expectEqualStrings("Unsent café\nContinue writing here", widget.model.comments[index].body.text());
    try std.testing.expect(widget.model.comments[index].draft);
    try std.testing.expectEqual(@as(u64, 17), widget.generation);
    try std.testing.expectEqual(@as(u64, 29), widget.text_revision);
    try std.testing.expectEqual(@as(f32, 142), widget.scroll);
    try std.testing.expectEqualDeep(@as(?[2]usize, .{ 5, 12 }), widget.copy_range);
    try std.testing.expect(widget.model.available);
    try std.testing.expectEqual(.sent, widget.delivery);
    try std.testing.expectEqualStrings(initial_patch, widget.model.current().source);
    try std.testing.expectEqualStrings(corrected_patch, widget.model.revisions[1].source);
}

test "review prototype rejects correction from another session or changed base without mutating the review" {
    const initial = try parse(.{ .schema = 1, .session_id = "session-a", .revisions = &.{.{ .id = "edition-a", .patch = initial_patch }}, .status = .reviewable });
    defer initial.deinit();
    const widget = try widgetFrom(initial);
    defer std.testing.allocator.destroy(widget);
    widget.delivery = .sending;
    widget.model.select(.{ .row = 1, .extend = false });
    widget.model.comment();
    const index = widget.model.editing.?;
    const anchor = widget.model.comments[index].anchor;
    _ = widget.model.comments[index].body.replace(.{ 0, 0 }, "Preserve this draft");

    const mismatches = [_]LiveResponse{
        .{ .schema = 1, .session_id = "other-session", .revisions = &.{ .{ .id = "edition-a", .patch = initial_patch }, .{ .id = "edition-b", .patch = corrected_patch } }, .status = .complete },
        .{ .schema = 1, .session_id = "session-a", .revisions = &.{ .{ .id = "different-base-id", .patch = initial_patch }, .{ .id = "edition-b", .patch = corrected_patch } }, .status = .complete },
        .{ .schema = 1, .session_id = "session-a", .revisions = &.{ .{ .id = "edition-a", .patch = corrected_patch }, .{ .id = "edition-b", .patch = corrected_patch } }, .status = .complete },
    };
    for (mismatches) |response| {
        const corrected = try parse(response);
        defer corrected.deinit();
        try std.testing.expectError(error.StaleReviewCorrection, live_review.accept(widget, .{ .initial = initial, .corrected = corrected }));
        try std.testing.expectEqual(@as(usize, 0), widget.model.revision);
        try std.testing.expectEqual(@as(usize, 0), widget.model.revisions[1].file_count);
        try std.testing.expect(!widget.model.available);
        try std.testing.expectEqual(.sending, widget.delivery);
        try std.testing.expectEqual(index, widget.model.editing.?);
        try std.testing.expectEqualDeep(anchor, widget.model.comments[index].anchor);
        try std.testing.expectEqualStrings("Preserve this draft", widget.model.comments[index].body.text());
        try std.testing.expectEqualStrings(initial_patch, widget.model.current().source);
    }
}

test "review prototype reconnect during correction restores sent comments and rejects inconsistent edition states" {
    const working = try parse(.{
        .schema = 1,
        .session_id = "session-a",
        .revisions = &.{.{ .id = "edition-a", .patch = initial_patch }},
        .comments = &.{.{ .file = "sample.txt", .side = .after, .first_line = 30, .last_line = 31, .body = "Already delivered café" }},
        .status = .working,
    });
    defer working.deinit();
    const widget = try widgetFrom(working);
    defer std.testing.allocator.destroy(widget);
    try std.testing.expectEqual(.sending, widget.delivery);
    try std.testing.expect(!widget.model.available);
    try std.testing.expectEqual(@as(usize, 0), widget.model.revision);
    try std.testing.expect(widget.model.comments[0].alive);
    try std.testing.expect(!widget.model.comments[0].draft);
    try std.testing.expectEqualStrings("Already delivered café", widget.model.comments[0].body.text());
    try std.testing.expectEqual(@as(usize, 1), widget.model.comments[0].anchor.first);
    try std.testing.expectEqual(@as(usize, 3), widget.model.comments[0].anchor.last);

    const inconsistent = [_]LiveResponse{
        .{ .schema = 1, .session_id = "session-a", .revisions = &.{.{ .id = "edition-a", .patch = initial_patch }}, .status = .complete },
        .{ .schema = 1, .session_id = "session-a", .revisions = &.{ .{ .id = "edition-a", .patch = initial_patch }, .{ .id = "edition-b", .patch = corrected_patch } }, .status = .reviewable },
        .{ .schema = 1, .session_id = "session-a", .revisions = &.{ .{ .id = "edition-a", .patch = initial_patch }, .{ .id = "edition-b", .patch = corrected_patch } }, .status = .working },
        .{ .schema = 1, .session_id = "session-a", .revisions = &.{ .{ .id = "edition-a", .patch = initial_patch }, .{ .id = "edition-a", .patch = corrected_patch } }, .status = .complete },
    };
    for (inconsistent) |response| {
        try std.testing.expectError(error.InvalidReviewResponse, parse(response));
    }
}
