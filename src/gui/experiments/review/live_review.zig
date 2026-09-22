const client = @import("telar-client");
const std = @import("std");
const Widget = @import("../../change_review/Widget.zig");
const LiveSnapshot = @import("LiveSnapshot.zig");
const ReviewFeedback = @import("ReviewFeedback.zig");
const LiveBridge = @import("LiveBridge.zig");

/// Rehydrates retained editions and delivered comments before opening the window.
/// Example: `try live_review.load(widget, snapshot);`
pub fn load(w: *Widget, snapshot: *LiveSnapshot) !void {
    const value = snapshot.parsed.value;
    var anchors: [client.change_review_limits.comments]client.ChangeReviewAnchor = undefined;
    for (value.comments, 0..) |comment, index| {
        anchors[index] = try locate(&snapshot.revisions[0], comment);
    }

    w.mode = .external;
    w.model = .{};
    w.model.revisions = snapshot.revisions;
    for (0..value.revisions.len) |index| {
        w.roles[index] = snapshot.roles[index];
    }
    w.model.available = value.revisions.len == 2;
    w.model.selectFile(0);
    for (value.comments, 0..) |comment, index| {
        w.model.comments[index] = .{ .anchor = anchors[index], .alive = true, .draft = false };
        _ = w.model.comments[index].body.replace(.{ 0, 0 }, comment.body);
    }
    w.delivery = if (value.status == .complete) .sent else if (value.status == .@"error") .failed else if (value.status == .working) .sending else .idle;
    w.model.status = if (value.status == .complete) "Review delivered. Edition 2 contains the agent's correction." else if (value.status == .working) "The agent is correcting the submitted review. Waiting for edition 2." else "Live experiment · save comments, then Send review. Unsent drafts stay in this window.";
    if (value.@"error") |message| {
        w.model.status = message;
    }
}

/// Called only after the previous GPU frame releases its borrowed resources.
/// Example: `dirty = live_review.pump(widget) or dirty;`
pub fn pump(w: *Widget, bridge: *LiveBridge) bool {
    if (w.delivery == .queued) {
        bridge.submit(&w.model) catch |err| {
            w.delivery = .idle;
            w.model.status = if (err == error.NoSavedComments) "Save at least one comment before sending the review." else "Review could not be queued. Existing comments are unchanged.";
            return true;
        };
        w.delivery = .sending;
        w.model.status = "Review is being delivered. You can keep reading this edition.";
        return true;
    }

    if (!bridge.ready.swap(false, .acq_rel)) {
        return false;
    }

    if (bridge.failure) |err| {
        w.delivery = .failed;
        w.model.status = std.fmt.bufPrint(&w.live_status, "Delivery interrupted: {s}. Reopen to check the coordinator's retained result.", .{@errorName(err)}) catch "Review delivery failed.";
        return true;
    }
    const snapshot = bridge.result.?;
    const value = snapshot.parsed.value;
    if (value.status == .@"error") {
        w.delivery = .failed;
        w.model.status = value.@"error" orelse "Agent correction failed. Existing review remains available.";
        return true;
    }

    accept(w, .{ .initial = bridge.initial.?, .corrected = snapshot }) catch {
        w.delivery = .failed;
        w.model.status = "Correction does not belong to this review. Existing edition retained.";
    };
    return true;
}

/// A correction cannot replace the version under the user's cursor or editor.
/// Example: `try live_review.accept(widget, corrected_snapshot);`
pub fn accept(w: *Widget, snapshots: struct { initial: *LiveSnapshot, corrected: *LiveSnapshot }) !void {
    const initial = snapshots.initial.parsed.value;
    const snapshot = snapshots.corrected;
    const value = snapshot.parsed.value;
    if (value.status != .complete or value.revisions.len != 2 or !std.mem.eql(u8, initial.session_id, value.session_id) or !std.mem.eql(u8, initial.revisions[0].id, value.revisions[0].id) or !std.mem.eql(u8, initial.revisions[0].patch, value.revisions[0].patch)) {
        return error.StaleReviewCorrection;
    }

    w.model.revisions[1] = snapshot.revisions[1];
    w.roles[1] = snapshot.roles[1];
    w.model.simulate();
    w.delivery = .sent;
    w.model.status = "Review delivered. The agent's correction is available in edition 2.";
}

fn locate(revision: *const client.ChangeReviewRevision, comment: ReviewFeedback) !client.ChangeReviewAnchor {
    const file_index = revision.findFile(comment.file) orelse return error.InvalidReviewComment;
    const file = revision.files[file_index];
    var first: ?usize = null;
    var last: ?usize = null;
    const before = comment.side == .before;
    for (revision.rows[file.first..file.last], file.first..) |row, index| {
        if (row.before() != before) {
            continue;
        }
        const number = (if (before) row.value.old else row.value.new) orelse continue;
        if (number == comment.first_line) {
            first = index;
        }
        if (number == comment.last_line) {
            last = index;
        }
    }
    const start = first orelse return error.InvalidReviewComment;
    const end = last orelse return error.InvalidReviewComment;
    if (end < start or revision.rows[start].hunk != revision.rows[end].hunk) {
        return error.InvalidReviewComment;
    }
    return .{ .revision = 0, .file = file_index, .first = start, .last = end, .before = before };
}
