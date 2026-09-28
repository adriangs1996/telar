//! Native runtime review controls, including cooperative feedback without PTY input.
const core = @import("telar-core");
const std = @import("std");
const Options = @import("arguments/ReviewOptions.zig");
const Session = @import("Session.zig");
const Snapshot = @import("Snapshot.zig");
const PaneRef = @import("PaneRef.zig");
const Context = @import("ExecutionContext.zig");
const control = @import("control.zig");

const max_listed_editions = 32;

/// Attaches to an existing runtime and executes one explicit review command.
/// Example: `try review.run(init, options);`
pub fn run(init: std.process.Init, options: Options) !u8 {
    var session = Session.attach(init, options.socket) catch |err| {
        std.debug.print("telar review: {s}\n", .{control.describe(err)});
        return 1;
    };
    defer session.close();
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    defer output.interface.flush() catch {};
    execute(&session, options, .{ .writer = &output.interface, .environ = init.minimal.environ }) catch |err| {
        std.debug.print("telar review: {s}\n", .{session.failure_reason orelse control.describe(err)});
        return 1;
    };
    return 0;
}

fn execute(session: *Session, options: Options, context: Context) !void {
    if (options.action == .list) {
        try list(session, options, context);
        return;
    }

    const pane = try resolvePane(session, options, context.environ);
    if (options.action == .show) {
        const current = try session.fetchReview(pane, .{ .edition = options.edition, .session = options.session });
        try writeResult(context.writer, &current, options.json);
        return;
    }

    var command: core.ChangeReviewCommand = .{
        .request_id = .none,
        .pane_id = try core.pane(pane.pane_id),
        .pane_generation = pane.pane_generation,
        .edition_id = options.edition,
        .expected_revision = options.expected_revision orelse 0,
        .action = switch (options.action) {
            .comment => .save_comment,
            .delete => .delete_comment,
            .submit => .submit,
            .reviewed => .mark_reviewed,
            .feedback => .feedback,
            .ack => .ack_feedback,
            else => unreachable,
        },
        .comment_id = options.comment_id,
        .path = options.path,
        .first_line = options.first_line,
        .last_line = options.last_line,
        .side = options.side,
        .body = options.body,
        .draft = options.draft,
        .reviewed = options.reviewed,
        .provider = options.provider,
        .session = options.session,
        .feedback_id = options.feedback_id,
    };
    if (options.action != .feedback and options.action != .ack) {
        const current = try session.fetchReview(pane, .{ .edition = options.edition, .session = options.session });
        command.edition_id = current.edition_id;
        command.expected_revision = options.expected_revision orelse current.revision;
        command.session = current.session;
    }

    const result = try session.commandReview(command);
    if (options.action == .feedback) {
        try writeFeedback(context.writer, &result, options.json);
    } else if (options.json) {
        try writeJson(context.writer, &result);
    } else {
        try context.writer.print("Edition {d} · revision {d} · {s}\n", .{ result.edition_id, result.revision, result.status });
    }
}

fn resolvePane(session: *Session, options: Options, environ: std.process.Environ) !PaneRef {
    if (options.target == .current) {
        return .{ .pane_id = try control.currentPaneId(environ), .pane_generation = try control.currentPaneGeneration(environ) };
    }

    var snapshot: Snapshot = .{};
    try session.fetchAgents(&snapshot);
    const found = try snapshot.resolve(options.target, environ) orelse return error.PaneNotFound;
    return .{ .pane_id = found.pane_id, .pane_generation = found.pane_generation };
}

fn list(session: *Session, options: Options, context: Context) !void {
    const pane = try resolvePane(session, options, context.environ);
    const writer = context.writer;
    if (options.json) {
        try writer.writeByte('[');
    }

    var edition: u64 = options.edition;
    var owner: [core.change_review.max_identity_bytes]u8 = undefined;
    var owner_len: usize = options.session.len;
    @memcpy(owner[0..owner_len], options.session);
    var count: usize = 0;
    while (count < max_listed_editions) : (count += 1) {
        const current = try session.fetchReview(pane, .{ .edition = edition, .session = owner[0..owner_len] });
        owner_len = current.session.len;
        @memcpy(owner[0..owner_len], current.session);
        if (current.edition_id == 0) {
            if (!options.json) {
                try writer.writeAll("No captured changes.\n");
            }

            break;
        }

        if (options.json) {
            if (count != 0) {
                try writer.writeByte(',');
            }

            try writer.print("{{\"edition_id\":{d},\"source\":\"{s}\",\"comments\":{d},\"status\":", .{ current.edition_id, @tagName(current.source), current.comment_count });
            try control.writeJsonString(writer, current.status);
            try writer.writeByte('}');
        } else {
            try writer.print("{d}  {s}  {d} comments  {s}\n", .{ current.edition_id, @tagName(current.source), current.comment_count, current.status });
        }

        if (current.previous_edition_id == 0 or current.previous_edition_id == edition) {
            break;
        }

        edition = current.previous_edition_id;
    }

    if (options.json) {
        try writer.writeAll("]\n");
    }
}

fn writeResult(writer: *std.Io.Writer, view: *const core.ChangeReviewSnapshotView, json: bool) !void {
    if (json) {
        try writeJson(writer, view);
        return;
    }

    try writer.print("Edition {d} · revision {d} · {s}\n{s}\n", .{ view.edition_id, view.revision, @tagName(view.source), view.status });
    try writer.writeAll(view.patch);
    for (view.comments()) |comment| {
        try writer.print("\nComment {d}: {s} {s}:{d}-{d}{s}\n{s}\n", .{ comment.id, comment.path, @tagName(comment.side), comment.first_line, comment.last_line, if (comment.draft) " (draft)" else "", comment.body });
    }
}

fn writeFeedback(writer: *std.Io.Writer, view: *const core.ChangeReviewSnapshotView, json: bool) !void {
    if (json) {
        try writer.print("{{\"feedback_id\":{d},\"feedback\":", .{view.feedback_id});
        try control.writeJsonString(writer, view.feedback);
        try writer.writeAll("}\n");
    } else if (view.feedback_id != 0) {
        try writer.print("Feedback {d}\n{s}\n", .{ view.feedback_id, view.feedback });
    }
}

fn writeJson(writer: *std.Io.Writer, view: *const core.ChangeReviewSnapshotView) !void {
    try writer.print("{{\"pane_id\":{d},\"pane_generation\":{d},\"edition_id\":{d},\"latest_edition_id\":{d},\"revision\":{d},\"source\":\"{s}\",\"delivery\":\"{s}\",\"reviewed\":{},\"status\":", .{ core.raw(view.pane_id), view.pane_generation, view.edition_id, view.latest_edition_id, view.revision, @tagName(view.source), @tagName(view.delivery), view.reviewed });
    try control.writeJsonString(writer, view.status);
    try writer.writeAll(",\"session\":");
    try control.writeJsonString(writer, view.session);
    try writer.writeAll(",\"patch\":");
    try control.writeJsonString(writer, view.patch);
    try writer.writeAll(",\"comments\":[");
    for (view.comments(), 0..) |comment, index| {
        if (index != 0) {
            try writer.writeByte(',');
        }

        try writer.print("{{\"id\":{d},\"path\":", .{comment.id});
        try control.writeJsonString(writer, comment.path);
        try writer.print(",\"side\":\"{s}\",\"first_line\":{d},\"last_line\":{d},\"draft\":{},\"body\":", .{ @tagName(comment.side), comment.first_line, comment.last_line, comment.draft });
        try control.writeJsonString(writer, comment.body);
        try writer.writeByte('}');
    }

    try writer.writeAll("]}\n");
}

test "review CLI JSON preserves line anchors and marks observed snapshots explicitly" {
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    var view: core.ChangeReviewSnapshotView = .{ .request_id = @enumFromInt(1), .pane_id = try core.pane(1), .pane_generation = 3, .edition_id = 8, .revision = 9, .source = .observed_snapshot, .patch = "@@ -1 +1 @@\n-a\n+b\n", .comment_count = 1 };
    view.comment_storage[0] = .{ .id = 2, .path = "file.go", .first_line = 3, .last_line = 5, .body = "café\nnext" };
    try writeJson(&writer.writer, &view);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, writer.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("observed_snapshot", parsed.value.object.get("source").?.string);
    const comment = parsed.value.object.get("comments").?.array.items[0].object;
    try std.testing.expectEqual(@as(i64, 5), comment.get("last_line").?.integer);
    try std.testing.expectEqualStrings("café\nnext", comment.get("body").?.string);
}
