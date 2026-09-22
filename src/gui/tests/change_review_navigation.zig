const data = @import("model");
const input_support = @import("input_support.zig");
const std = @import("std");
const client = @import("telar-client");
const Session = @import("Session.zig");
const review = @import("change_review.zig");
const native = @import("../native/native.zig");
const Target = @import("../widgets/interaction/Target.zig");
const actions = @import("../change_review/action.zig");

const search_patch = "diff --git a/file.zig b/file.zig\n--- a/file.zig\n+++ b/file.zig\n@@ -1,4 +1,4 @@\n-old\n+café.* first\n café wildcard trap\n café.* second\n tail\n";
const long_line_count = 100;

fn withPatch(source: []const u8) !*Session {
    const session = try review.base();
    errdefer session.deinit();
    try session.gui.openChangeReview(Session.pane_id);
    var snapshot = review.response(session, 1);
    snapshot.patch = source;
    try review.reply(session, snapshot);
    try review.adopt(session);
    try review.publish(session);
    return session;
}

fn longPatch(buffer: []u8) ![]const u8 {
    var len = (try std.fmt.bufPrint(buffer, "diff --git a/file.zig b/file.zig\n--- a/file.zig\n+++ b/file.zig\n@@ -1,{d} +1,{d} @@\n-old\n+new\n", .{ long_line_count, long_line_count })).len;
    for (1..long_line_count) |line| {
        len += (try std.fmt.bufPrint(buffer[len..], " line {d:0>3}{s}\n", .{ line, if (line == 10 or line == 50 or line == 90) " needle" else "" })).len;
    }

    return buffer[0..len];
}

fn typeText(session: *Session, text: []const u8) !void {
    try review.send(session, .{ .text = .{ .bytes = text } });
}

fn press(session: *Session, code: data.Key.Code) !void {
    try review.send(session, .{ .key = .{ .code = code } });
    try review.send(session, .{ .key = .{ .code = code, .phase = .release } });
}

fn control(session: *Session, letter: []const u8) !void {
    try review.send(session, .{ .key = .{ .code = .{ .char = .init(letter) }, .mods = .{ .ctrl = true } } });
    try review.send(session, .{ .key = .{ .code = .{ .char = .init(letter) }, .mods = .{ .ctrl = true }, .phase = .release } });
}

fn beginSearch(session: *Session) !Target {
    try typeText(session, "/");
    try review.publish(session);
    const target = session.gui.widgets.dispatcher.focusedTarget() orelse return error.SearchNotFocused;
    try std.testing.expect(target.action == .custom);
    try std.testing.expectEqual(actions.Kind.search, actions.kind(target.action.custom).?);
    return target;
}

test "runtime review delivered gg and G navigate file boundaries without leaking terminal input" {
    var source: [8192]u8 = undefined;
    const session = try withPatch(try longPatch(&source));
    defer session.deinit();
    const widget = &session.gui.review.widget;
    const file = widget.model.current().files[0];
    try typeText(session, "G");
    try std.testing.expectEqual(file.last - 1, widget.model.head);
    try review.publish(session);
    try std.testing.expect(widget.scroll > 0);
    try typeText(session, "g");
    try std.testing.expectEqual(file.last - 1, widget.model.head);
    try typeText(session, "g");
    try std.testing.expectEqual(file.first, widget.model.head);
    try review.publish(session);
    try std.testing.expectEqual(@as(f32, 0), widget.scroll);
    try session.settle();
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
}

test "runtime review half page motions follow the delivered viewport height" {
    var source: [8192]u8 = undefined;
    const session = try withPatch(try longPatch(&source));
    defer session.deinit();
    const widget = &session.gui.review.widget;
    const first = widget.model.head;
    const tall_height = widget.viewport.height;
    try control(session, "d");
    const tall_distance = widget.model.head - first;
    try std.testing.expect(tall_distance > 1);
    const moved_pixels = widget.viewport.ends[widget.model.head] - widget.viewport.ends[first];
    try std.testing.expect(@abs(moved_pixels - tall_height / 2) < widget.viewport.line_height);
    try review.publish(session);
    try control(session, "u");
    try std.testing.expectEqual(first, widget.model.head);
    try review.publish(session);

    const size = try session.gui.resizeViewport(
        .{
            .width = 1100,
            .height = 450,
            .scale = 1,
        },
    );
    try session.gui.resize(size, session.gui.renderer.theme);
    session.gui.pointer.configure(session.gui.renderer.origin, size);
    try review.publish(session);
    try std.testing.expect(widget.viewport.height < tall_height);
    try control(session, "d");
    const short_distance = widget.model.head - first;
    try std.testing.expect(short_distance > 0 and short_distance < tall_distance);
    try review.publish(session);
    try control(session, "u");
    try std.testing.expectEqual(first, widget.model.head);
}

test "runtime review half page motion ignores the viewport from a failed frame" {
    var source: [8192]u8 = undefined;
    const session = try withPatch(try longPatch(&source));
    defer session.deinit();
    const widget = &session.gui.review.widget;
    const first = widget.model.head;
    const delivered_height = widget.viewport.height;
    try control(session, "d");
    const delivered_destination = widget.model.head;
    try control(session, "u");
    try std.testing.expectEqual(first, widget.model.head);

    const size = try session.gui.resizeViewport(
        .{
            .width = 1100,
            .height = 450,
            .scale = 1,
        },
    );
    try session.gui.resize(size, session.gui.renderer.theme);
    session.gui.pointer.configure(session.gui.renderer.origin, size);
    const rejected = try session.draw();
    try std.testing.expect(widget.prepared_viewport.height < delivered_height);
    try std.testing.expectEqual(delivered_height, widget.viewport.height);
    try input_support.presented(
        session.gui,
        rejected,
        false,
    );
    try std.testing.expectEqual(delivered_height, widget.viewport.height);
    try control(session, "d");
    try std.testing.expectEqual(delivered_destination, widget.model.head);
}

test "runtime review search accepts literal UTF8 and n N repeat before Escape clears it" {
    const session = try withPatch(search_patch);
    defer session.deinit();
    const widget = &session.gui.review.widget;
    _ = try beginSearch(session);
    try typeText(session, "café.*");
    try std.testing.expectEqual(@as(usize, 1), widget.model.head);
    try std.testing.expectEqualStrings("café.*", widget.model.search.query.text());
    try press(session, .enter);
    try std.testing.expect(!widget.search_prompt.open);
    try review.publish(session);
    try typeText(session, "n");
    try std.testing.expectEqual(@as(usize, 3), widget.model.head);
    try typeText(session, "N");
    try std.testing.expectEqual(@as(usize, 1), widget.model.head);
    try typeText(session, "N");
    try std.testing.expectEqual(@as(usize, 3), widget.model.head);
    try press(session, .escape);
    try std.testing.expectEqualStrings("", widget.model.search.query.text());
    try std.testing.expect(widget.model.search.match == null);
    try std.testing.expect(session.gui.review.active);
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
}

test "runtime review search reveals the matching wrapped fragment instead of the line end" {
    const padding: [1400]u8 = @splat('x');
    var source: [4096]u8 = undefined;
    const patch = try std.fmt.bufPrint(&source, "diff --git a/file.zig b/file.zig\n--- a/file.zig\n+++ b/file.zig\n@@ -1 +1 @@\n-old\n+needle {s} needle\n", .{padding});
    const session = try withPatch(patch);
    defer session.deinit();
    const widget = &session.gui.review.widget;
    const size = try session.gui.resizeViewport(
        .{
            .width = 1100,
            .height = 450,
            .scale = 1,
        },
    );
    try session.gui.resize(size, session.gui.renderer.theme);
    session.gui.pointer.configure(session.gui.renderer.origin, size);
    try review.publish(session);
    _ = try beginSearch(session);
    try typeText(session, "needle");
    try press(session, .enter);
    try review.publish(session);
    const first = widget.model.search.match.?;
    try std.testing.expectEqual(@as(usize, 0), first.start);
    const offset = widget.model.current().rows[first.row].offset;
    try std.testing.expect(visibleFragment(session, offset));
    const first_scroll = widget.scroll;

    try typeText(session, "n");
    try review.publish(session);
    try std.testing.expectEqual(first.row, widget.model.search.match.?.row);
    try std.testing.expect(widget.model.search.match.?.start > padding.len);
    try std.testing.expect(widget.scroll > first_scroll);
    try std.testing.expect(!visibleFragment(session, offset));
    try typeText(session, "N");
    try review.publish(session);
    try std.testing.expectEqual(@as(usize, 0), widget.model.search.match.?.start);
    try std.testing.expect(visibleFragment(session, offset));
}

fn visibleFragment(session: *Session, offset: usize) bool {
    const registry = session.gui.widgets.dispatcher.maps.presented();
    for (registry.targets[0..registry.len]) |target| {
        if (target.action == .custom and actions.kind(target.action.custom) == .code and actions.item(target.action.custom) == offset and target.bounds.width > 0 and target.bounds.height > 0) {
            return true;
        }
    }

    return false;
}

test "runtime review page motions scroll a single logical line across its wrapped fragments" {
    const padding: [4000]u8 = @splat('x');
    var source: [8192]u8 = undefined;
    const patch = try std.fmt.bufPrint(&source, "diff --git a/file.zig b/file.zig\n--- a/file.zig\n+++ b/file.zig\n@@ -0,0 +1 @@\n+{s}\n", .{padding});
    const session = try withPatch(patch);
    defer session.deinit();
    const widget = &session.gui.review.widget;
    const size = try session.gui.resizeViewport(
        .{
            .width = 1100,
            .height = 450,
            .scale = 1,
        },
    );
    try session.gui.resize(size, session.gui.renderer.theme);
    session.gui.pointer.configure(session.gui.renderer.origin, size);
    try review.publish(session);
    try std.testing.expectEqual(@as(usize, 1), widget.model.current().row_count);
    const page = widget.viewport.height;
    try std.testing.expect(widget.maximum_scroll > 2 * page);

    try press(session, .page_down);
    try review.publish(session);
    try std.testing.expectApproxEqAbs(page, widget.scroll, 0.01);
    try std.testing.expectEqual(@as(usize, 0), widget.model.head);
    try control(session, "d");
    try review.publish(session);
    try std.testing.expectApproxEqAbs(page * 1.5, widget.scroll, 0.01);
    const before_search = widget.scroll;
    _ = try beginSearch(session);
    try std.testing.expectEqual(before_search, widget.scroll);
    try typeText(session, "missing");
    try press(session, .enter);
    try review.publish(session);
    try std.testing.expectEqual(before_search, widget.scroll);
    try control(session, "u");
    try review.publish(session);
    try std.testing.expectApproxEqAbs(page, widget.scroll, 0.01);
    try press(session, .page_up);
    try review.publish(session);
    try std.testing.expectEqual(@as(f32, 0), widget.scroll);
}

test "runtime review code drag keeps its owner when it confirms search" {
    const session = try withPatch(search_patch);
    defer session.deinit();
    const widget = &session.gui.review.widget;
    _ = try beginSearch(session);
    try typeText(session, "café");
    try review.publish(session);
    const row = widget.model.current().rows[1];
    const registry = session.gui.widgets.dispatcher.maps.presented();
    var code: ?Target = null;
    for (registry.targets[0..registry.len]) |target| {
        if (target.action == .custom and actions.kind(target.action.custom) == .code and actions.item(target.action.custom) == row.offset) {
            code = target;
            break;
        }
    }

    const target = code orelse return error.MissingCodeControl;
    const x = target.bounds.x;
    const y = target.bounds.y + target.bounds.height / 2;
    try review.send(session, .{ .pointer = .{ .kind = .press, .button = .left, .x = x, .y = y } });
    try review.publish(session);
    try review.send(session, .{ .pointer = .{ .kind = .drag, .button = .left, .x = x + 4 * widget.cell, .y = y } });
    try review.send(session, .{ .pointer = .{ .kind = .release, .button = .left, .x = x + 4 * widget.cell, .y = y } });
    try std.testing.expect(!widget.search_prompt.open);
    try std.testing.expect(!widget.dragging);
    try control(session, "c");
    var request: native.HostRequest = .{};
    try std.testing.expect(session.gui.host.next(&request));
    try std.testing.expectEqualStrings("café", request.text.?[0..request.len]);
}

test "runtime review unmatched search stays on its line and cancellation restores the previous view" {
    var source: [8192]u8 = undefined;
    const session = try withPatch(try longPatch(&source));
    defer session.deinit();
    const widget = &session.gui.review.widget;
    _ = try beginSearch(session);
    try typeText(session, "needle");
    try press(session, .enter);
    try review.publish(session);
    try typeText(session, "n");
    try review.publish(session);
    try typeText(session, "v");
    const head = widget.model.head;
    const tail = widget.model.tail;
    const scroll = widget.scroll;
    try std.testing.expect(scroll > 0);

    _ = try beginSearch(session);
    try typeText(session, "line 099");
    try review.publish(session);
    try std.testing.expect(widget.model.head > head);
    try std.testing.expect(widget.scroll > scroll);
    try press(session, .escape);
    try std.testing.expectEqual(head, widget.model.head);
    try std.testing.expectEqual(tail, widget.model.tail);
    try std.testing.expect(widget.model.visual);
    try std.testing.expectEqual(scroll, widget.scroll);
    try std.testing.expectEqualStrings("needle", widget.model.search.query.text());
    try review.publish(session);
    try std.testing.expectEqual(scroll, widget.scroll);

    _ = try beginSearch(session);
    try typeText(session, "absent literal");
    try std.testing.expect(widget.model.search.match == null);
    try std.testing.expectEqual(head, widget.model.head);
    try press(session, .enter);
    try std.testing.expectEqualStrings("absent literal", widget.model.search.query.text());
    try review.publish(session);
    try typeText(session, "n");
    try std.testing.expectEqual(head, widget.model.head);
    try std.testing.expect(session.gui.review.active);
}

test "runtime review comment editing keeps navigation letters as ordinary text" {
    const session = try withPatch(search_patch);
    defer session.deinit();
    const widget = &session.gui.review.widget;
    _ = try beginSearch(session);
    try typeText(session, "café");
    try press(session, .enter);
    try review.publish(session);
    try typeText(session, "c");
    try review.publish(session);
    const index = widget.model.editing.?;
    const head = widget.model.head;
    var context: native.TextContext = .{};
    try std.testing.expect(widget.textContext(&context));
    const target = session.gui.widgets.dispatcher.focusedTarget().?;
    try std.testing.expectEqual(actions.Kind.editor, actions.kind(target.action.custom).?);
    try std.testing.expectEqual(target.id.target_id, context.target_id);
    for ([_][]const u8{ "g", "g", "G", "/", "n", "N" }) |text| {
        try typeText(session, text);
    }

    try std.testing.expectEqualStrings("ggG/nN", widget.model.comments[index].body.text());
    try std.testing.expectEqual(head, widget.model.head);
    try std.testing.expect(!widget.search_prompt.open);
    try std.testing.expect(!widget.pending_g);
    try std.testing.expect(widget.model.comments[index].draft);
    try std.testing.expectEqualStrings("café", widget.model.search.query.text());
}

test "runtime review read only search rejects oversized multiline and invalid UTF8 input atomically" {
    const session = try withPatch(search_patch);
    defer session.deinit();
    const widget = &session.gui.review.widget;
    widget.read_only = true;
    const target = try beginSearch(session);
    try typeText(session, "café");
    try std.testing.expectEqualStrings("café", widget.search_prompt.field.text());
    const too_long: [257]u8 = @splat('x');
    for ([_][]const u8{ &too_long, "two\nlines", "two\rlines", "nul\x00byte" }) |text| {
        try review.send(session, .{ .accessibility = .{ .target_id = target.id.target_id, .generation = target.id.generation, .action = .set_value, .text = text } });
        try std.testing.expectEqualStrings("café", widget.search_prompt.field.text());
        try std.testing.expectEqualStrings("café", widget.model.search.query.text());
    }

    const queued = session.gui.input_queue.len;
    try std.testing.expect(!try session.gui.acceptInput(.{ .accessibility = .{ .target_id = target.id.target_id, .generation = target.id.generation, .action = .set_value, .text = "\xff" } }));
    try std.testing.expectEqual(queued, session.gui.input_queue.len);
    try std.testing.expectEqualStrings("café", widget.search_prompt.field.text());
    try press(session, .backspace);
    try std.testing.expectEqualStrings("caf", widget.model.search.query.text());
    try press(session, .enter);
    try std.testing.expect(!widget.search_prompt.open);
    try std.testing.expect(widget.read_only);
    try std.testing.expectEqual(@as(u32, 0), widget.changed_comments);
}

test "runtime review search preedit cancels before query and clipboard retains its revision owner" {
    const session = try withPatch(search_patch);
    defer session.deinit();
    const widget = &session.gui.review.widget;
    const target = try beginSearch(session);
    try typeText(session, "caf");
    try review.send(session, .{ .composition = .{ .target_id = target.id.target_id, .generation = target.id.generation, .text = "é", .selection_start = 2, .selection_end = 2 } });
    try std.testing.expect(session.gui.widgets.preedit.owner != null);
    try std.testing.expectEqualStrings("caf", widget.search_prompt.field.text());
    try press(session, .escape);
    try std.testing.expect(session.gui.widgets.preedit.owner == null);
    try std.testing.expect(widget.search_prompt.open);
    try std.testing.expectEqualStrings("caf", widget.search_prompt.field.text());

    try control(session, "v");
    var request: native.HostRequest = .{};
    try std.testing.expect(session.gui.host.next(&request));
    try review.send(session, .{ .clipboard = .{ .request_id = request.request_id, .target_id = request.target_id, .generation = request.generation, .status = .success, .text = "é.*" } });
    try std.testing.expectEqualStrings("café.*", widget.model.search.query.text());
    try control(session, "v");
    try std.testing.expect(session.gui.host.next(&request));
    try press(session, .backspace);
    try review.send(session, .{ .clipboard = .{ .request_id = request.request_id, .target_id = request.target_id, .generation = request.generation, .status = .success, .text = "late" } });
    try std.testing.expectEqualStrings("café.", widget.search_prompt.field.text());
    try press(session, .escape);
    try std.testing.expect(!widget.search_prompt.open);
    try std.testing.expectEqualStrings("", widget.model.search.query.text());
}

test "runtime review search commits and activates Next with one delivered click" {
    const patch = "diff --git a/file.zig b/file.zig\n--- a/file.zig\n+++ b/file.zig\n@@ -1 +1 @@\n-before\n+café first\n@@ -10 +10 @@\n-other\n+café second\n";
    const session = try withPatch(patch);
    defer session.deinit();
    const widget = &session.gui.review.widget;
    _ = try beginSearch(session);
    try typeText(session, "café");
    try review.publish(session);
    try std.testing.expectEqual(@as(usize, 1), widget.model.head);
    const registry = session.gui.widgets.dispatcher.maps.presented();
    var next: ?Target = null;
    for (registry.targets[0..registry.len]) |target| {
        if (target.action == .custom and actions.kind(target.action.custom) == .next) {
            next = target;
            break;
        }
    }

    const target = next orelse return error.MissingNextControl;
    const x = target.bounds.x + target.bounds.width / 2;
    const y = target.bounds.y + target.bounds.height / 2;
    try review.send(session, .{ .pointer = .{ .kind = .press, .button = .left, .x = x, .y = y } });
    try review.send(session, .{ .pointer = .{ .kind = .release, .button = .left, .x = x, .y = y } });
    try std.testing.expect(!widget.search_prompt.open);
    try std.testing.expectEqual(@as(usize, 2), widget.model.head);
    try std.testing.expectEqualStrings("café", widget.model.search.query.text());
}
