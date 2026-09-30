//! File evidence and cooperative feedback for agents in ordinary terminal panes.
const core = @import("telar-core");
const std = @import("std");
const Session = @import("Session.zig");
const PaneRef = @import("PaneRef.zig");
const ReviewHookReport = @import("ReviewHookReport.zig");
const ReviewHookFiles = @import("ReviewHookFiles.zig");
const ReviewFileSample = @import("ReviewFileSample.zig");
const control = @import("control.zig");
const limit_reached = @import("limit_reached.zig");

/// Runs only inside the hook subprocess; failed evidence never becomes a diff.
/// Example: `hook_review.capture(session, pane, report);`
pub fn capture(session: *Session, pane: PaneRef, report: ReviewHookReport) void {
    const input = report.input;
    const phase: core.change_review.SamplePhase = if (std.mem.eql(u8, input.event, "PreToolUse")) .before else if (std.mem.eql(u8, input.event, "PostToolUse")) .after else return;
    if (input.session.len == 0 or input.session.len > core.change_review.max_identity_bytes or input.tool_call_id.len > core.change_review.max_identity_bytes) {
        return;
    }

    const pane_id = core.pane(pane.pane_id) catch return;
    const files = ReviewHookFiles.collect(report.provider, input) catch return;
    if (files.skipped != 0) {
        limit_reached.report(session, .{
            .limit = ReviewHookFiles.files_limit,
            .requested = files.count + files.skipped,
        });
    }

    // Heap: the sample is as large as the largest file the review keeps.
    const sample = session.gpa.create(ReviewFileSample) catch return;
    defer session.gpa.destroy(sample);
    sample.* = .{};

    var largest_skipped: u64 = 0;
    for (files.paths[0..files.count]) |path| {
        const absolute = if (std.fs.path.isAbsolute(path)) session.gpa.dupe(u8, path) catch continue else std.fs.path.join(session.gpa, &.{ input.cwd, path }) catch continue;
        defer session.gpa.free(absolute);
        if (absolute.len > core.change_review.max_path_bytes) {
            continue;
        }

        sample.read(session.io, absolute) catch |err| {
            if (err == error.ReviewFileTooLarge) {
                largest_skipped = @max(largest_skipped, sample.size);
            }

            continue;
        };

        // A refused file, one at a runtime limit included (the runtime
        // reports that one itself), leaves the other files' evidence.
        session.reportReviewSample(.{
            .request_id = .none,
            .pane_id = pane_id,
            .pane_generation = pane.pane_generation,
            .provider = report.provider,
            .session = input.session,
            .tool_call_id = input.tool_call_id,
            .phase = phase,
            .path = absolute,
            .exists = sample.exists,
            .content = sample.storage[0..sample.len],
        }) catch continue;
    }

    if (largest_skipped != 0) {
        limit_reached.report(session, .{
            .limit = core.change_review.sample_limit,
            .requested = largest_skipped,
        });
    }
}

/// Delivers only explicitly submitted feedback through the provider's hook API.
/// Example: `try hook_review.feedback(session, pane, report);`
pub fn feedback(session: *Session, pane: PaneRef, report: ReviewHookReport) !void {
    const input = report.input;
    // Cursor's tool hooks document no context field that reaches the model.
    if (report.provider == .pi or report.provider == .cursor or input.session.len == 0 or (input.agent_id != null and input.agent_id.?.len != 0)) {
        return;
    }

    if (!std.mem.eql(u8, input.event, "PreToolUse") and !std.mem.eql(u8, input.event, "PostToolUse") and !std.mem.eql(u8, input.event, "UserPromptSubmit")) {
        return;
    }

    var command = core.ChangeReviewCommand{
        .request_id = .none,
        .pane_id = try core.pane(pane.pane_id),
        .pane_generation = pane.pane_generation,
        .action = .feedback,
        .provider = report.provider,
        .session = input.session,
    };
    const pending = try session.commandReview(command);
    if (pending.feedback_id == 0 or pending.feedback.len == 0) {
        return;
    }

    var output_buffer: [1024]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(session.io, &output_buffer);
    try writeFeedback(&output.interface, input.event, pending.feedback);
    try output.interface.flush();
    command.action = .ack_feedback;
    command.edition_id = pending.edition_id;
    command.feedback_id = pending.feedback_id;
    _ = try session.commandReview(command);
}

fn writeFeedback(writer: *std.Io.Writer, event: []const u8, text: []const u8) !void {
    try writer.writeAll("{\"hookSpecificOutput\":{\"hookEventName\":");
    try control.writeJsonString(writer, event);
    try writer.writeAll(",\"additionalContext\":");
    try control.writeJsonString(writer, text);
    try writer.writeAll("}}\n");
}

test "review hook feedback is valid official JSON and preserves Unicode and newlines" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeFeedback(&output.writer, "PostToolUse", "Review #7: café\n\"quote\"\\path");
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output.written(), .{});
    defer parsed.deinit();
    const specific = parsed.value.object.get("hookSpecificOutput").?.object;
    try std.testing.expectEqualStrings("PostToolUse", specific.get("hookEventName").?.string);
    try std.testing.expectEqualStrings("Review #7: café\n\"quote\"\\path", specific.get("additionalContext").?.string);
}
