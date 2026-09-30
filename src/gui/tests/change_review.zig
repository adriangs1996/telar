const event_module = @import("../input/event.zig");
const input_support = @import("input_support.zig");
const data = @import("model");
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Session = @import("Session.zig");
const PointerEvent = @import("../input/PointerEvent.zig");
const syntaxhl = @import("syntaxhl");
const syntax_limits = @import("../syntax/limits.zig");

const patch = "diff --git a/file.zig b/file.zig\n--- a/file.zig\n+++ b/file.zig\n@@ -1,3 +1,3 @@\n-old\n+new\n context\n tail\n";

pub fn base() !*Session {
    const session = try Session.init();
    errdefer session.deinit();
    try session.bootstrap();
    const size = try session.gui.resizeViewport(
        .{
            .width = 1100,
            .height = 750,
            .scale = 1,
        },
    );
    try session.gui.resize(size, session.gui.renderer.theme);
    session.gui.pointer.configure(session.gui.renderer.origin, size);
    _ = session.gui.app.model.panes.find(Session.pane_id).?.identify(77);
    try session.settle();
    return session;
}

pub fn ready() !*Session {
    const session = try base();
    errdefer session.deinit();
    try session.gui.openChangeReview(Session.pane_id);
    try reply(session, response(session, 1));
    try adopt(session);
    try publish(session);
    return session;
}

pub fn response(session: *Session, revision: u64) core.ChangeReviewSnapshotView {
    return .{ .request_id = session.gui.app.model.change_review.pending.?, .pane_id = Session.pane_id, .pane_generation = 77, .session = "thread-A", .edition_id = 1, .latest_edition_id = 1, .revision = revision, .patch = patch };
}

pub fn reply(session: *Session, snapshot: core.ChangeReviewSnapshotView) !void {
    try session.settle();
    var bytes: [128 * 1024]u8 = undefined;
    const encoded = try core.encodeChangeReviewSnapshot(&bytes, snapshot);
    _ = try client.runtime_messages.handleServerMessage(session.gui.app, try core.decodeServer(encoded));
    @memset(&bytes, 0);
    try session.gui.review.synchronize(session.gui.app);
}

pub fn adopt(session: *Session) !void {
    try prepare(
        session,
        .{
            .allocator = std.testing.allocator,
            .job_ms = syntax_limits.job_ms,
        },
    );
}

// Prepares the loaded edition as the observation worker would, then lets the
// adapter loop's synchronize finish it.
fn prepare(session: *Session, context: struct { allocator: std.mem.Allocator, job_ms: i64 }) !void {
    const panel = session.gui.review;
    const state = &session.gui.app.model.change_review;
    const index = 1 - panel.visible_slot;
    const slot = &panel.slots[index];
    slot.generation = state.generation;
    slot.edition = state.snapshot.edition_id;
    slot.len = state.snapshot.patch.len;
    @memcpy(slot.source[0..slot.len], state.snapshot.patch);
    slot.build(.{
        .allocator = context.allocator,
        .io = std.testing.io,
        .job_ms = context.job_ms,
    });
    try std.testing.expect(slot.failure == null);

    panel.job = index;
    panel.notify();
    try panel.synchronize(session.gui.app);
}

pub fn publish(session: *Session) !void {
    const token = try session.draw();
    try input_support.presented(
        session.gui,
        token,
        true,
    );
    try session.settle();
}

fn draft(session: *Session, body: []const u8) usize {
    const widget = &session.gui.review.widget;
    widget.model.select(.{ .row = 1, .extend = false });
    widget.model.select(.{ .row = 2, .extend = true });
    widget.model.comment();
    const index = widget.model.editing.?;
    _ = widget.model.comments[index].body.replace(.{ 0, 0 }, body);
    widget.noteComment(index);
    return index;
}

fn withComment(snapshot: core.ChangeReviewSnapshotView, body: []const u8) core.ChangeReviewSnapshotView {
    var value = snapshot;
    value.comment_count = 1;
    value.comment_storage[0] = .{ .id = 91, .path = "file.zig", .first_line = 1, .last_line = 2, .body = body, .draft = true };
    return value;
}

pub fn send(session: *Session, event: event_module.Event) !void {
    try input_support.accept(session.gui, event);
    try input_support.pump(session.gui);
}

test "runtime review autosave acknowledges only submitted text while later typing stays queued" {
    const session = try ready();
    defer session.deinit();
    const panel = session.gui.review;
    const index = draft(session, "first");
    try panel.synchronize(session.gui.app);
    const first = (try core.decodeClient(try session.sent())).change_review_command;
    try std.testing.expectEqualStrings("first", first.body);
    try std.testing.expectEqual(@as(u32, 1), first.first_line);
    try std.testing.expectEqual(@as(u32, 2), first.last_line);
    try std.testing.expect(first.draft);
    try std.testing.expectEqualStrings("thread-A", first.session);
    try std.testing.expect(panel.widget.model.comments[index].pending);

    _ = panel.widget.model.comments[index].body.replace(.{ 0, 5 }, "first and later");
    panel.widget.noteComment(index);
    try reply(session, withComment(response(session, 2), "first"));
    try std.testing.expectEqualStrings("first and later", panel.widget.model.comments[index].body.text());
    const next = (try core.decodeClient(try session.sent())).change_review_command;
    try std.testing.expectEqual(@as(u64, 91), next.comment_id);
    try std.testing.expectEqualStrings("first and later", next.body);
    try reply(session, withComment(response(session, 3), "first and later"));
    try std.testing.expectEqual(@as(u32, 0), panel.widget.changed_comments);
    try std.testing.expect(!panel.widget.model.comments[index].pending);
}

test "runtime review rejection preserves unsaved range draft and late success cannot consume it" {
    const session = try ready();
    defer session.deinit();
    const panel = session.gui.review;
    const index = draft(session, "keep my feedback");
    try panel.synchronize(session.gui.app);
    const stale = response(session, 2);
    try session.settle();
    _ = try client.runtime_messages.handleServerMessage(
        session.gui.app,
        .{
            .request_failed = .{
                .request_id = stale.request_id,
                .code = .internal,
                .message = "Review changed; refresh before saving",
            },
        },
    );
    try panel.synchronize(session.gui.app);
    try std.testing.expect(panel.blocked);
    try std.testing.expect(panel.widget.changed_comments != 0);
    try std.testing.expectEqualStrings("keep my feedback", panel.widget.model.comments[index].body.text());
    _ = try client.runtime_messages.handleServerMessage(
        session.gui.app,
        .{
            .change_review_snapshot = withComment(stale, "server reply"),
        },
    );
    try panel.synchronize(session.gui.app);
    try std.testing.expectEqualStrings("keep my feedback", panel.widget.model.comments[index].body.text());
    try std.testing.expect(panel.blocked);
}

test "runtime review close and reopen restores its acknowledged draft on the same edition" {
    const session = try ready();
    defer session.deinit();
    const panel = session.gui.review;
    const index = draft(session, "saved draft");
    try panel.synchronize(session.gui.app);
    try reply(session, withComment(response(session, 2), "saved draft"));
    panel.widget.command = .close;
    try panel.synchronize(session.gui.app);
    try std.testing.expect(!panel.active);
    try session.gui.openChangeReview(Session.pane_id);
    try std.testing.expectEqual(@as(u64, 1), (try core.decodeClient(try session.sent())).query_change_review.edition_id);
    try reply(session, withComment(response(session, 2), "saved draft"));
    try std.testing.expect(panel.active);
    try std.testing.expectEqualStrings("saved draft", panel.widget.model.comments[index].body.text());
    try std.testing.expect(panel.widget.model.comments[index].draft);
}

test "runtime review newer editions remain explicit while its immutable patch stays visible" {
    const session = try ready();
    defer session.deinit();
    const panel = session.gui.review;
    try client.change_review.queryChangeReview(&session.gui.app.model, 1);
    var snapshot = response(session, 2);
    snapshot.latest_edition_id = 2;
    snapshot.next_edition_id = 2;
    try reply(session, snapshot);
    try std.testing.expectEqual(@as(u64, 1), panel.edition);
    try std.testing.expect(panel.widget.next_edition);
    try std.testing.expectEqualStrings(patch, panel.widget.model.current().source);
    panel.widget.command = .next_edition;
    try panel.synchronize(session.gui.app);
    try std.testing.expectEqual(@as(u64, 2), (try core.decodeClient(try session.sent())).query_change_review.edition_id);
    snapshot = response(session, 3);
    snapshot.edition_id = 2;
    snapshot.latest_edition_id = 2;
    snapshot.previous_edition_id = 1;
    try reply(session, snapshot);
    try std.testing.expectEqual(@as(u64, 1), panel.edition);
    try adopt(session);
    try std.testing.expectEqual(@as(u64, 2), panel.edition);
}

test "runtime review failed preparation keeps the old edition read only and retries the requested edition" {
    const session = try ready();
    defer session.deinit();
    const gui = session.gui;
    const panel = gui.review;
    try client.change_review.queryChangeReview(&gui.app.model, 1);
    var snapshot = response(session, 2);
    snapshot.latest_edition_id = 2;
    snapshot.next_edition_id = 2;
    snapshot.status = "Capture warning: one tool event could not be recorded.";
    try reply(session, snapshot);
    try std.testing.expectEqualStrings(snapshot.status, panel.widget.model.status);
    try std.testing.expectEqualStrings("Agent-reported patch", panel.widget.source_label);
    panel.widget.command = .next_edition;
    try panel.synchronize(gui.app);
    try std.testing.expect(panel.widget.read_only);
    try std.testing.expect(panel.widget.loading);
    snapshot = response(session, 3);
    snapshot.edition_id = 2;
    snapshot.latest_edition_id = 2;
    snapshot.previous_edition_id = 1;
    snapshot.source = .observed_snapshot;
    try reply(session, snapshot);
    const index = 1 - panel.visible_slot;
    panel.slots[index].generation = gui.app.model.change_review.generation;
    panel.slots[index].edition = 2;
    panel.slots[index].failure = error.ReviewLineLimit;
    panel.job = index;
    panel.notify();
    try panel.synchronize(gui.app);
    try std.testing.expectEqual(@as(u64, 1), panel.edition);
    try std.testing.expectEqualStrings(patch, panel.widget.model.current().source);
    try std.testing.expect(panel.widget.read_only);
    try std.testing.expect(!panel.widget.loading);
    try std.testing.expect(std.mem.indexOf(u8, panel.widget.model.status, "file or line limit") != null);
    panel.widget.command = .refresh;
    try panel.synchronize(gui.app);
    try std.testing.expectEqual(@as(u64, 2), (try core.decodeClient(try session.sent())).query_change_review.edition_id);
    snapshot.request_id = gui.app.model.change_review.pending.?;
    try reply(session, snapshot);
    try adopt(session);
    try std.testing.expectEqual(@as(u64, 2), panel.edition);
    try std.testing.expectEqualStrings("Before/after snapshot", panel.widget.source_label);
    try std.testing.expect(!panel.widget.read_only);
}

test "runtime review adopts an edition highlighted up to its fragment limit and reports the limit" {
    const session = try base();
    defer session.deinit();

    // A context line is a fragment on each side and an added line on one, so
    // this edition asks for one fragment past the limit within the view's rows.
    const header = "diff --git a/file.zig b/file.zig\n--- a/file.zig\n+++ b/file.zig\n";
    const context = "@@ -1 +1 @@\n const value = 1;\n";
    const added = "@@ -0,0 +1 @@\n+const last = 2;\n";
    const pairs = syntax_limits.fragments / 2;
    const text = try std.testing.allocator.alloc(u8, header.len + pairs * context.len + added.len);
    defer std.testing.allocator.free(text);

    @memcpy(text[0..header.len], header);
    for (0..pairs) |index| {
        @memcpy(text[header.len + index * context.len ..][0..context.len], context);
    }

    @memcpy(text[header.len + pairs * context.len ..], added);
    try session.gui.openChangeReview(Session.pane_id);
    var snapshot = response(session, 1);
    snapshot.patch = text;
    try reply(session, snapshot);
    try prepare(
        session,
        .{
            .allocator = std.testing.allocator,
            .job_ms = std.math.maxInt(i64),
        },
    );

    const panel = session.gui.review;
    const roles = panel.widget.roles[0];
    try std.testing.expectEqual(@as(u64, 1), panel.edition);
    try std.testing.expect(!panel.widget.read_only);
    try std.testing.expect(!panel.widget.loading);
    try std.testing.expectEqual(text.len, roles.len);
    try std.testing.expectEqual(syntaxhl.Role.keyword, roles[std.mem.lastIndexOf(u8, text, "const value").?]);
    try std.testing.expectEqual(syntaxhl.Role.plain, roles[std.mem.lastIndexOf(u8, text, "const last").?]);

    const reaches = &session.gui.app.model.limit_reaches;
    const slot = reaches.find("syntax.job_fragments").?;
    try std.testing.expectEqual(@as(u64, 1), reaches.hits[slot]);
    try std.testing.expectEqual(@as(u64, syntax_limits.fragments), reaches.value[slot]);
}

test "runtime review adopts an edition past its time budget with the roles it highlighted" {
    const session = try base();
    defer session.deinit();

    try session.gui.openChangeReview(Session.pane_id);
    var snapshot = response(session, 1);
    snapshot.patch = "diff --git a/file.zig b/file.zig\n--- a/file.zig\n+++ b/file.zig\n@@ -0,0 +1 @@\n+const first = 1;\n@@ -0,0 +9 @@\n+const second = 2;\n";
    try reply(session, snapshot);
    try prepare(
        session,
        .{
            .allocator = std.testing.allocator,
            .job_ms = 0,
        },
    );

    const panel = session.gui.review;
    const roles = panel.widget.roles[0];
    try std.testing.expectEqual(@as(u64, 1), panel.edition);
    try std.testing.expect(!panel.widget.read_only);
    try std.testing.expectEqual(syntaxhl.Role.keyword, roles[std.mem.indexOf(u8, snapshot.patch, "const first").?]);
    try std.testing.expectEqual(syntaxhl.Role.plain, roles[std.mem.indexOf(u8, snapshot.patch, "const second").?]);
    try std.testing.expect(session.gui.app.model.limit_reaches.find("syntax.job_ms") != null);
}

test "runtime review adopts an edition whose highlighting failed as plain text" {
    const session = try base();
    defer session.deinit();

    try session.gui.openChangeReview(Session.pane_id);
    try reply(session, response(session, 1));
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try prepare(
        session,
        .{
            .allocator = failing.allocator(),
            .job_ms = syntax_limits.job_ms,
        },
    );

    const panel = session.gui.review;
    try std.testing.expectEqual(@as(u64, 1), panel.edition);
    try std.testing.expect(!panel.widget.read_only);
    try std.testing.expect(std.mem.allEqual(syntaxhl.Role, panel.widget.roles[0], .plain));
    try std.testing.expect(session.gui.app.model.limit_reaches.find("syntax.job_fragments") == null);
    try std.testing.expect(session.gui.app.model.limit_reaches.find("syntax.job_ms") == null);
}

test "runtime review modal consumes new terminal input" {
    const session = try ready();
    defer session.deinit();
    try send(session, .{ .text = .{ .bytes = "ls", .physical = .{ .value = 90 } } });
    try send(session, .{ .key = .{ .code = .enter, .physical = .{ .value = 91 } } });
    try send(session, .{ .key = .{ .code = .enter, .physical = .{ .value = 91 }, .phase = .release } });
    try session.settle();
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
}

test "runtime review modal releases previously held terminal keys without forwarding new presses" {
    const session = try base();
    defer session.deinit();
    session.gui.app.model.panes.find(Session.pane_id).?.input_modes.kitty_keyboard_flags = 10;
    try publish(session);
    try send(session, .{ .key = .{ .code = .enter, .physical = .{ .value = 91 } } });
    try session.settle();
    const pressed = session.input_len;
    try std.testing.expect(pressed > 0);
    try session.gui.openChangeReview(Session.pane_id);
    try send(session, .{ .key = .{ .code = .enter, .physical = .{ .value = 91 }, .phase = .release } });
    try session.settle();
    try std.testing.expect(session.input_len > pressed);
    try std.testing.expectEqual(@as(usize, 0), session.gui.router.leases.len);
    try std.testing.expectEqual(@as(usize, 0), session.gui.widgets.dispatcher.keys.len);
}

test "runtime review modal retires a held terminal mouse gesture before swallowing its later release" {
    const session = try base();
    defer session.deinit();
    const gui = session.gui;
    const tab = gui.app.model.tabs.active;
    gui.app.model.panes.find(Session.pane_id).?.mouse = .{ .sgr = true, .tracking = .button };
    try publish(session);
    const view = data.tab_layout.view(&gui.app.model, tab, Session.pane_id, data.workbench.region(&gui.app.model).area).?;
    const x = @as(f64, @floatFromInt(view.content.x)) * gui.app.model.host.host_size.cell_width_px + @as(f64, @floatFromInt(session.gui.renderer.origin[0])) + 1;
    const y = @as(f64, @floatFromInt(view.content.y)) * gui.app.model.host.host_size.cell_height_px + @as(f64, @floatFromInt(session.gui.renderer.origin[1])) + 1;
    try send(session, .{ .pointer = .{ .kind = .press, .button = .right, .x = x, .y = y } });
    try session.settle();
    const button = @intFromEnum(PointerEvent.Button.right);
    try std.testing.expect(gui.pointer.owners[button] == .child);
    try gui.openChangeReview(Session.pane_id);
    try session.settle();
    try std.testing.expect(gui.pointer.owners[button] == .shared);
    try std.testing.expect(std.mem.endsWith(u8, session.input[0..session.input_len], "m"));
    const retired = session.input_len;
    try send(session, .{ .pointer = .{ .kind = .release, .button = .right, .x = x, .y = y } });
    try session.settle();
    try std.testing.expectEqual(retired, session.input_len);
}

test "runtime review consumes retired widget key releases before its first frame" {
    const session = try base();
    defer session.deinit();
    const gui = session.gui;
    try publish(session);
    const registry = gui.widgets.dispatcher.maps.presented();
    try std.testing.expect(gui.widgets.dispatcher.keys.acquire(.{ .value = 92 }, .{ .widget = registry.targets[0].id }));
    try gui.openChangeReview(Session.pane_id);
    try send(session, .{ .key = .{ .code = .enter, .physical = .{ .value = 92 }, .phase = .release } });
    try session.settle();
    try std.testing.expectEqual(@as(usize, 0), gui.widgets.dispatcher.keys.len);
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
}

test "runtime review coalesces new edition notices behind pending saves without replacing its patch" {
    const session = try ready();
    defer session.deinit();
    const panel = session.gui.review;
    const index = draft(session, "feedback");
    try panel.synchronize(session.gui.app);
    const save_id = session.gui.app.model.change_review.pending.?;
    _ = try client.runtime_messages.handleServerMessage(
        session.gui.app,
        .{
            .change_review_changed = .{
                .pane_id = Session.pane_id,
                .pane_generation = 77,
                .session = "thread-A",
                .latest_edition_id = 2,
            },
        },
    );
    try std.testing.expectEqual(save_id, session.gui.app.model.change_review.pending.?);
    try reply(session, withComment(response(session, 2), "feedback"));
    const query = (try core.decodeClient(try session.sent())).query_change_review;
    try std.testing.expectEqual(@as(u64, 1), query.edition_id);
    try std.testing.expectEqualStrings("thread-A", query.session);
    var snapshot = withComment(response(session, 2), "feedback");
    snapshot.latest_edition_id = 2;
    snapshot.next_edition_id = 2;
    try reply(session, snapshot);
    try std.testing.expectEqual(@as(u64, 1), panel.edition);
    try std.testing.expect(panel.widget.next_edition);
    try std.testing.expectEqualStrings("feedback", panel.widget.model.comments[index].body.text());
    try std.testing.expectEqualStrings(patch, panel.widget.model.current().source);
}

test "runtime review retains a retired conversation draft and explicitly reopens the new session" {
    const session = try ready();
    defer session.deinit();
    const gui = session.gui;
    const index = draft(session, "copy this before closing");
    try gui.review.synchronize(gui.app);
    const stale = response(session, 2);
    try session.settle();
    _ = try client.runtime_messages.handleServerMessage(
        gui.app,
        .{
            .change_review_changed = .{
                .pane_id = Session.pane_id,
                .pane_generation = 77,
                .session = "thread-B",
                .latest_edition_id = 0,
            },
        },
    );
    try gui.review.synchronize(gui.app);
    try std.testing.expect(gui.review.widget.read_only);
    try std.testing.expectEqualStrings("copy this before closing", gui.review.widget.model.comments[index].body.text());
    gui.review.widget.command = .close;
    try gui.review.synchronize(gui.app);
    try std.testing.expect(!gui.review.active);
    try gui.openChangeReview(Session.pane_id);
    const request = (try core.decodeClient(try session.sent())).query_change_review;
    try std.testing.expectEqual(@as(u64, 0), request.edition_id);
    try std.testing.expectEqualStrings("", request.session);
    _ = try client.runtime_messages.handleServerMessage(
        gui.app,
        .{
            .change_review_snapshot = stale,
        },
    );
    try std.testing.expectEqual(request.request_id, gui.app.model.change_review.pending.?);
    var snapshot = response(session, 1);
    snapshot.session = "thread-B";
    try reply(session, snapshot);
    try adopt(session);
    try std.testing.expectEqualStrings("thread-B", gui.app.model.change_review.snapshot.session);
    try std.testing.expect(!gui.review.widget.model.comments[index].alive);
}

test "runtime review renders a valid long basename in its file sidebar" {
    const session = try base();
    defer session.deinit();
    var filename: [240]u8 = @splat('a');
    @memcpy(filename[filename.len - 4 ..], ".txt");
    var buffer: [2048]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "diff --git a/{s} b/{s}\n--- a/{s}\n+++ b/{s}\n@@ -1 +1 @@\n-old\n+new\n", .{ filename, filename, filename, filename });
    try session.gui.openChangeReview(Session.pane_id);
    var snapshot = response(session, 1);
    snapshot.patch = text;
    try reply(session, snapshot);
    try adopt(session);
    try std.testing.expectEqualStrings(&filename, session.gui.review.widget.model.current().files[0].path);
    try publish(session);
}

test "runtime review loads through its real worker and inbox after the previous frame is delivered" {
    const session = try base();
    defer session.deinit();
    const gui = session.gui;
    gui.job_hook = null;
    try client.runtime_io.startRuntimeRead(gui.app);
    try gui.openChangeReview(Session.pane_id);
    _ = try gui.update();
    var buffer: [128 * 1024]u8 = undefined;
    const request = (try core.decodeClient(try session.peer.receive(std.testing.io, &buffer))).query_change_review;
    try std.testing.expectEqual(gui.app.model.change_review.pending.?, request.request_id);
    try std.testing.expectEqual(@as(u64, 0), request.edition_id);
    try session.peer.send(std.testing.io, try core.encodeChangeReviewSnapshot(&buffer, response(session, 1)));
    while (!gui.app.model.change_review.loaded) {
        try session.gui.driver.inbox.wait();
        _ = try gui.update();
    }
    const token = try session.draw();
    try std.testing.expect(gui.review.job != null);
    while (!gui.review.notified) {
        try session.gui.driver.inbox.wait();
        _ = try gui.update();
    }
    try std.testing.expectEqual(@as(u64, 0), gui.review.edition);
    try input_support.presented(
        gui,
        token,
        true,
    );
    try publish(session);
    try std.testing.expectEqual(@as(u64, 1), gui.review.edition);
    try std.testing.expect(!gui.review.widget.loading);
    try std.testing.expect(gui.review.widget.model.current().row_count > 0);
    const registry = gui.widgets.dispatcher.maps.presented();
    var comment_button = false;
    for (registry.targets[0..registry.len]) |target| {
        if (std.mem.eql(u8, target.label[0..target.label_len], "Comment")) {
            comment_button = true;
        }
    }
    try std.testing.expect(comment_button);
}
