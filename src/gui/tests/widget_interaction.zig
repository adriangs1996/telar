const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Dispatcher = @import("../widgets/interaction/Dispatcher.zig");
const Target = @import("../widgets/interaction/Target.zig");
const Id = @import("../widgets/interaction/Id.zig");
const Session = @import("Session.zig");
const native = @import("../native/native.zig");
const Event = @import("../input/event.zig").Event;

fn control(value: u64, x: f32) Target {
    return .{ .bounds = .{ .x = x, .y = 0, .width = 10, .height = 10 }, .action = .{ .custom = value } };
}

test "widget targets publish by delivery and preserve identities through reorder" {
    var dispatcher: Dispatcher = .{};
    _ = dispatcher.begin();
    const first = try dispatcher.add(control(1, 0));
    const second = try dispatcher.add(control(2, 20));
    dispatcher.seal();
    try std.testing.expect(!dispatcher.route(.{ .pointer = .{ .kind = .press, .x = 1, .y = 1 } }).consumed);
    dispatcher.present(true);
    const revision = dispatcher.revision;
    _ = dispatcher.begin();
    try std.testing.expect(second.eql(try dispatcher.add(control(2, 0))));
    try std.testing.expect(first.eql(try dispatcher.add(control(1, 20))));
    dispatcher.seal();
    dispatcher.present(false);
    try std.testing.expectEqual(revision, dispatcher.revision);
    try std.testing.expect(first.eql(dispatcher.maps.presented().at(.{ 1, 1 }).?.id));
    _ = dispatcher.begin();
    _ = try dispatcher.add(control(2, 0));
    _ = try dispatcher.add(control(1, 20));
    dispatcher.seal();
    dispatcher.present(true);
    try std.testing.expect(second.eql(dispatcher.maps.presented().at(.{ 1, 1 }).?.id));
    try std.testing.expect(dispatcher.revision > revision);
}

test "widget traversal keeps terminal keys and pointer releases with their original owners" {
    var dispatcher: Dispatcher = .{};
    _ = dispatcher.begin();
    const first = try dispatcher.add(control(1, 0));
    const second = try dispatcher.add(control(2, 20));
    dispatcher.seal();
    dispatcher.present(true);
    try std.testing.expect(!dispatcher.route(.{ .key = .{ .code = .tab } }).consumed);
    try std.testing.expect(!dispatcher.route(.{ .key = .{ .code = .enter, .physical = .{ .value = 7 } } }).consumed);
    try std.testing.expect(!dispatcher.route(.{ .pointer = .{ .kind = .press, .x = 100, .y = 100 } }).consumed);
    _ = dispatcher.route(.{ .pointer = .{ .kind = .press, .x = 1, .y = 1 } });
    _ = dispatcher.route(.{ .pointer = .{ .kind = .release, .x = 1, .y = 1 } });
    try std.testing.expect(first.eql(dispatcher.focused.?));
    _ = dispatcher.route(.{ .key = .{ .code = .tab } });
    try std.testing.expect(second.eql(dispatcher.focused.?));
    _ = dispatcher.route(.{ .key = .{ .code = .back_tab } });
    try std.testing.expect(first.eql(dispatcher.focused.?));
    dispatcher.begin().modal_layer = 1;
    var modal = control(3, 0);
    modal.layer = 1;
    _ = try dispatcher.add(modal);
    dispatcher.seal();
    dispatcher.present(true);
    try std.testing.expect(!dispatcher.route(.{ .key = .{ .code = .enter, .physical = .{ .value = 7 }, .phase = .release } }).consumed);
    try std.testing.expect(!dispatcher.route(.{ .pointer = .{ .kind = .release, .button = .right, .x = 100, .y = 100 } }).consumed);
}

test "retired generations and modal scope consume captured releases without retargeting" {
    var dispatcher: Dispatcher = .{};
    _ = dispatcher.begin();
    const first = try dispatcher.add(control(1, 0));
    dispatcher.seal();
    dispatcher.present(true);
    _ = dispatcher.route(.{ .pointer = .{ .kind = .press, .x = 1, .y = 1 } });
    _ = dispatcher.route(.{ .text = .{ .bytes = "a", .physical = .{ .value = 11 } } });
    dispatcher.begin().modal_layer = 1;
    _ = try dispatcher.add(control(1, 0));
    var modal = control(2, 20);
    modal.layer = 1;
    _ = try dispatcher.add(modal);
    dispatcher.seal();
    dispatcher.present(true);
    const release = dispatcher.route(.{ .pointer = .{ .kind = .release, .x = 21, .y = 1 } });
    try std.testing.expect(release.consumed and release.target == null);
    const lifted = dispatcher.route(.{ .text = .{ .bytes = "a", .physical = .{ .value = 11 }, .phase = .release } });
    try std.testing.expect(lifted.consumed and lifted.target == null);
    _ = dispatcher.begin();
    var replacement = control(1, 0);
    replacement.id.generation = 2;
    const new_id = try dispatcher.add(replacement);
    dispatcher.seal();
    dispatcher.present(true);
    try std.testing.expect(!first.eql(new_id));
    try std.testing.expect(dispatcher.maps.presented().find(first) == null);
}

fn publish(session: *Session) !void {
    const token = try session.gui.prepare(&session.renderer);
    try session.gui.complete(token, true);
    try session.settle();
}

fn initSession() !*Session {
    const session = try Session.init();
    errdefer session.deinit();
    try session.bootstrap();
    const size = try session.gui.measure(&session.renderer, .{ .width = 800, .height = 600, .scale = 1 });
    try session.gui.resize(size, session.renderer.theme);
    session.gui.input.setGeometry(session.renderer.origin, size);
    try session.settle();
    return session;
}

fn send(session: *Session, event: Event) !void {
    try session.gui.input.acceptEvent(event);
    try session.gui.input.drain(&session.gui.app);
}

fn editorTarget(session: *Session, wanted: Target.Field) !Target {
    const registry = session.gui.widgets.dispatcher.maps.presented();
    for (registry.targets[0..registry.len]) |target| {
        if (target.action == .text_field and target.action.text_field == wanted) {
            return target;
        }
    }

    return error.MissingEditor;
}

test "native prompt preedit owns bytes moves candidate caret and commits only to its generation" {
    const session = try initSession();
    defer session.deinit();
    const gui = session.gui;
    gui.app.model.name_prompt.begin(.{ .rename_tab = .{ .tab_id = Session.location.tab_id, .label = "hello" } });
    try publish(session);
    const target = try editorTarget(session, .name);
    var before: native.TextContext = .{};
    try std.testing.expect(gui.widgetTextContext(&before));
    var bytes = [_]u8{ 'x', 'y' };
    try gui.input.acceptEvent(.{ .composition = .{ .target_id = target.id.target_id, .generation = target.id.generation, .text = &bytes, .selection_start = 2, .selection_end = 2 } });
    @memset(&bytes, 'z');
    try gui.input.drain(&gui.app);
    try std.testing.expectEqualStrings("xy", gui.widgets.preedit.text());
    try std.testing.expectEqualStrings("hello", gui.app.model.name_prompt.currentConst().?.field.text());
    var after: native.TextContext = .{};
    try std.testing.expect(gui.widgetTextContext(&after));
    try std.testing.expectEqualStrings("hello", after.text.?[0..after.len]);
    try std.testing.expect(after.x > before.x);
    try send(session, .{ .text = .{ .target_id = target.id.target_id, .generation = target.id.generation, .bytes = "界" } });
    try std.testing.expectEqualStrings("hello界", gui.app.model.name_prompt.currentConst().?.field.text());
    try std.testing.expect(gui.widgets.preedit.owner == null);
    gui.app.model.name_prompt.begin(.{ .rename_tab = .{ .tab_id = Session.location.tab_id, .label = "new" } });
    try publish(session);
    try send(session, .{ .text = .{ .target_id = target.id.target_id, .generation = target.id.generation, .bytes = "stale" } });
    try std.testing.expectEqualStrings("new", gui.app.model.name_prompt.currentConst().?.field.text());
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
}

test "GUI field focus and key release do not move editing back to an old widget" {
    const session = try initSession();
    defer session.deinit();
    const gui = session.gui;
    gui.app.model.name_prompt.begin(.create_workspace);
    try publish(session);
    const name = try editorTarget(session, .name);
    const directory = try editorTarget(session, .directory);
    try send(session, .{ .key = .{ .code = .left, .physical = .{ .value = 22 } } });
    try send(session, .{ .pointer = .{ .kind = .press, .x = directory.bounds.x + 1, .y = directory.bounds.y + 1 } });
    try send(session, .{ .pointer = .{ .kind = .release, .x = directory.bounds.x + 1, .y = directory.bounds.y + 1 } });
    try std.testing.expect(gui.app.model.name_prompt.currentConst().?.form().?.focus == .directory);
    try send(session, .{ .key = .{ .code = .left, .physical = .{ .value = 22 }, .phase = .release } });
    try std.testing.expect(gui.app.model.name_prompt.currentConst().?.form().?.focus == .directory);
    try std.testing.expect(directory.id.eql(gui.widgets.dispatcher.focused.?));
    try send(session, .{ .key = .{ .code = .back_tab } });
    try publish(session);
    try std.testing.expect(name.id.eql(gui.widgets.dispatcher.focused.?));
}

test "clipboard and accessibility edit the delivered field and reject delayed retired owners" {
    const session = try initSession();
    defer session.deinit();
    const gui = session.gui;
    gui.app.model.name_prompt.begin(.{ .rename_tab = .{ .tab_id = Session.location.tab_id, .label = "start" } });
    try publish(session);
    const target = try editorTarget(session, .name);
    var tree: native.AccessibilityTree = .{};
    try std.testing.expect(gui.widgetAccessibility(&tree));
    try std.testing.expectEqual(@as(u32, 1), tree.count);
    try std.testing.expectEqual(@as(u32, 3), tree.nodes.?[0].role);
    try std.testing.expectEqualStrings("start", tree.nodes.?[0].value.?[0..tree.nodes.?[0].value_len]);
    try send(session, .{ .accessibility = .{ .target_id = target.id.target_id, .generation = target.id.generation, .action = .set_selection, .selection_start = 0, .selection_end = 5 } });
    try send(session, .{ .key = .{ .code = .{ .char = .init("v") }, .mods = .{ .super = true }, .physical = .{ .value = 3 } } });
    for (0..12) |_| {
        try send(session, .{ .key = .{ .code = .{ .char = .init("v") }, .mods = .{ .super = true }, .physical = .{ .value = 3 }, .phase = .repeat } });
    }

    var request: native.HostRequest = .{};
    try std.testing.expect(gui.host.next(&request));
    try std.testing.expectEqual(target.id.target_id, request.target_id);
    var empty: native.HostRequest = .{};
    try std.testing.expect(!gui.host.next(&empty));
    try send(session, .{ .clipboard = .{ .request_id = request.request_id, .target_id = request.target_id, .generation = request.generation, .status = .success, .text = "one\r\ntwo" } });
    try std.testing.expectEqualStrings("one two", gui.app.model.name_prompt.currentConst().?.field.text());
    try send(session, .{ .accessibility = .{ .target_id = target.id.target_id, .generation = target.id.generation, .action = .set_value, .text = "accessible" } });
    try std.testing.expectEqualStrings("accessible", gui.app.model.name_prompt.currentConst().?.field.text());
    try gui.requestClipboardRead(target.id.target_id, target.id.generation);
    try std.testing.expect(gui.host.next(&request));
    gui.app.model.name_prompt.begin(.{ .rename_tab = .{ .tab_id = Session.location.tab_id, .label = "replacement" } });
    try publish(session);
    try send(session, .{ .clipboard = .{ .request_id = request.request_id, .target_id = request.target_id, .generation = request.generation, .status = .success, .text = "late" } });
    try std.testing.expectEqualStrings("replacement", gui.app.model.name_prompt.currentConst().?.field.text());
}

test "whole widget paste preserves selection when its bounded field cannot hold it" {
    const session = try initSession();
    defer session.deinit();
    const gui = session.gui;
    gui.app.model.name_prompt.begin(.{ .rename_tab = .{ .tab_id = Session.location.tab_id, .label = "keep" } });
    try publish(session);
    _ = try client.controllers.name_prompts.handleInput(&gui.app, .{ .command = .select_all });
    try send(session, .{ .paste = "a" ** 8192 ++ "tail" });
    const prompt = gui.app.model.name_prompt.currentConst().?;
    try std.testing.expectEqualStrings("keep", prompt.field.text());
    try std.testing.expectEqualStrings("keep", prompt.field.selected());
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
}

test "activating chrome navigation returns subsequent text to the terminal" {
    const session = try initSession();
    defer session.deinit();
    try publish(session);
    const gui = session.gui;
    const registry = gui.widgets.dispatcher.maps.presented();
    var tab: ?Target = null;
    for (registry.targets[0..registry.len]) |target| {
        if (target.action == .intent and target.action.intent == .select_tab) {
            tab = target;
            break;
        }
    }

    const target = tab orelse return error.MissingTab;
    try send(session, .{ .pointer = .{ .kind = .press, .x = target.bounds.x + 1, .y = target.bounds.y + 1 } });
    try send(session, .{ .pointer = .{ .kind = .release, .x = target.bounds.x + 1, .y = target.bounds.y + 1 } });
    try send(session, .{ .text = .{ .bytes = "typed" } });
    try session.settle();
    try std.testing.expectEqualStrings("typed", session.input[0..session.input_len]);
}

test "targeted stale physical commits acquire a sink instead of falling back to terminal" {
    var dispatcher: Dispatcher = .{};
    const value: @import("../input/TextInput.zig") = .{ .bytes = "x", .physical = .{ .value = 25 }, .target_id = 9, .generation = 2 };
    const pressed = dispatcher.route(.{ .text = value });
    try std.testing.expect(pressed.consumed and pressed.target == null);
    var released = value;
    released.phase = .release;
    const lifted = dispatcher.route(.{ .text = released });
    try std.testing.expect(lifted.consumed and lifted.target == null);
}

test "native byte ranges reject partial scalars and preserve backwards selection" {
    const session = try initSession();
    defer session.deinit();
    const gui = session.gui;
    gui.app.model.name_prompt.begin(.{ .rename_tab = .{ .tab_id = Session.location.tab_id, .label = "a界b" } });
    try publish(session);
    const target = try editorTarget(session, .name);
    try send(session, .{ .accessibility = .{ .target_id = target.id.target_id, .generation = target.id.generation, .action = .set_selection, .selection_start = 4, .selection_end = 1 } });
    var context: native.TextContext = .{};
    try std.testing.expect(gui.widgetTextContext(&context));
    try std.testing.expectEqual(@as(u32, 4), context.selection_start);
    try std.testing.expectEqual(@as(u32, 1), context.selection_end);
    try send(session, .{ .composition = .{ .target_id = target.id.target_id, .generation = target.id.generation, .text = "界", .selection_start = 1, .selection_end = 1 } });
    try std.testing.expect(gui.widgets.preedit.owner == null);
    try send(session, .{ .composition = .{ .target_id = target.id.target_id, .generation = target.id.generation, .text = "x", .selection_start = 1, .selection_end = 1, .replacement_start = 2, .replacement_end = 4 } });
    try std.testing.expect(gui.widgets.preedit.owner == null);
    try send(session, .{ .accessibility = .{ .target_id = target.id.target_id, .generation = target.id.generation, .action = .paste, .selection_start = 2, .selection_end = 4 } });
    var request: native.HostRequest = .{};
    try std.testing.expect(!gui.host.next(&request));
    try std.testing.expectEqualStrings("a界b", gui.app.model.name_prompt.currentConst().?.field.text());
    try std.testing.expectEqualStrings("界", gui.app.model.name_prompt.currentConst().?.field.selected());
}

test "atomic field replacement protects selected text from invalid input capacity and aliasing" {
    var field: client.GenericField(8) = .init("a界b");
    _ = field.selectRange(.{ 4, 1 });
    try std.testing.expect(!field.replace(.{ 1, 4 }, "01234567"));
    try std.testing.expectEqualStrings("a界b", field.text());
    try std.testing.expectEqualStrings("界", field.selected());
    try std.testing.expect(!field.replace(.{ 2, 4 }, "x"));
    try std.testing.expect(!field.replace(.{ 1, 4 }, "\xff"));
    try std.testing.expectEqualStrings("界", field.selected());
    try std.testing.expect(field.replace(.{ 0, 1 }, field.text()[1..4]));
    try std.testing.expectEqualStrings("界界b", field.text());
}

test "cut waits for matching host success and preserves text on failure or intervening edit" {
    const session = try initSession();
    defer session.deinit();
    const gui = session.gui;
    gui.app.model.name_prompt.begin(.{ .rename_tab = .{ .tab_id = Session.location.tab_id, .label = "keep" } });
    try publish(session);
    const target = try editorTarget(session, .name);
    for ([_]@import("../input/ClipboardResult.zig").Status{ .unavailable, .cancelled, .success }) |status| {
        _ = try client.controllers.name_prompts.handleInput(&gui.app, .{ .command = .select_all });
        try send(session, .{ .key = .{ .code = .{ .char = .init("x") }, .mods = .{ .super = true } } });
        try std.testing.expectEqualStrings("keep", gui.app.model.name_prompt.currentConst().?.field.text());
        var request: native.HostRequest = .{};
        try std.testing.expect(gui.host.next(&request));
        try std.testing.expectEqual(target.id.target_id, request.target_id);
        try std.testing.expectEqualStrings("keep", request.text.?[0..request.len]);
        try send(session, .{ .clipboard = .{ .request_id = request.request_id, .target_id = request.target_id, .generation = request.generation, .status = status } });
        try std.testing.expectEqualStrings(if (status == .success) "" else "keep", gui.app.model.name_prompt.currentConst().?.field.text());
    }

    try send(session, .{ .text = .{ .bytes = "original" } });
    _ = try client.controllers.name_prompts.handleInput(&gui.app, .{ .command = .select_all });
    try send(session, .{ .key = .{ .code = .{ .char = .init("x") }, .mods = .{ .ctrl = true } } });
    var request: native.HostRequest = .{};
    try std.testing.expect(gui.host.next(&request));
    try send(session, .{ .text = .{ .bytes = "changed" } });
    try send(session, .{ .clipboard = .{ .request_id = request.request_id, .target_id = request.target_id, .generation = request.generation, .status = .success } });
    try std.testing.expectEqualStrings("changed", gui.app.model.name_prompt.currentConst().?.field.text());
    for (gui.widgets.pending_cuts) |pending| {
        try std.testing.expect(pending == null);
    }
}

test "clipboard capacity leaves cut selection intact and composition follows outside edits" {
    const session = try initSession();
    defer session.deinit();
    const gui = session.gui;
    gui.app.model.name_prompt.begin(.{ .rename_tab = .{ .tab_id = Session.location.tab_id, .label = "keep" } });
    try publish(session);
    const target = try editorTarget(session, .name);
    for (0..4) |_| {
        try gui.requestClipboardRead(target.id.target_id, target.id.generation);
    }

    _ = try client.controllers.name_prompts.handleInput(&gui.app, .{ .command = .select_all });
    try send(session, .{ .key = .{ .code = .{ .char = .init("x") }, .mods = .{ .ctrl = true } } });
    try std.testing.expectEqualStrings("keep", gui.app.model.name_prompt.currentConst().?.field.selected());
    try send(session, .{ .composition = .{ .target_id = target.id.target_id, .generation = target.id.generation, .text = "temp", .selection_start = 4, .selection_end = 4 } });
    var context: native.TextContext = .{};
    try std.testing.expect(gui.widgetTextContext(&context));
    try std.testing.expectEqual(@as(u32, 1), context.composition_active);
    try send(session, .{ .accessibility = .{ .target_id = target.id.target_id, .generation = target.id.generation, .action = .set_value, .text = "changed" } });
    try std.testing.expect(gui.widgetTextContext(&context));
    try std.testing.expectEqual(@as(u32, 0), context.composition_active);
    try std.testing.expectEqualStrings("changed", context.text.?[0..context.len]);
}

test "new modal blocks already delivered background actions before its first frame" {
    const session = try initSession();
    defer session.deinit();
    const gui = session.gui;
    try publish(session);
    const registry = gui.widgets.dispatcher.maps.presented();
    var toggle: ?Target = null;
    for (registry.targets[0..registry.len]) |target| {
        if (target.action == .intent and target.action.intent == .toggle_sidebar) {
            toggle = target;
            break;
        }
    }

    const target = toggle orelse return error.MissingToggle;
    const visible = gui.app.model.sidebarVisible();
    gui.app.model.name_prompt.begin(.{ .rename_tab = .{ .tab_id = Session.location.tab_id, .label = "modal" } });
    try send(session, .{ .pointer = .{ .kind = .press, .x = target.bounds.x + 1, .y = target.bounds.y + 1 } });
    try send(session, .{ .pointer = .{ .kind = .release, .x = target.bounds.x + 1, .y = target.bounds.y + 1 } });
    try send(session, .{ .accessibility = .{ .target_id = target.id.target_id, .generation = target.id.generation, .action = .press } });
    try std.testing.expectEqual(visible, gui.app.model.sidebarVisible());
    try std.testing.expectEqualStrings("modal", gui.app.model.name_prompt.currentConst().?.field.text());
}

test "extreme wheel deltas and cancellation keep sidebar scroll state finite" {
    const session = try initSession();
    defer session.deinit();
    const gui = session.gui;
    try publish(session);
    const sidebar = gui.chrome.presented().bands.sidebar;
    try std.testing.expect(sidebar.width > 0);
    try send(session, .{ .scroll = .{ .x = sidebar.x + 1, .y = sidebar.y + 1, .delta_y = std.math.floatMax(f64), .phase = .begin } });
    try std.testing.expect(std.math.isFinite(gui.widgets.sidebar_scroll_remainder));
    try send(session, .{ .scroll = .{ .x = sidebar.x + 1, .y = sidebar.y + 1, .delta_y = 0.25, .precise = true, .phase = .update } });
    try std.testing.expectEqual(@as(f64, 0.25), gui.widgets.sidebar_scroll_remainder);
    const offset = gui.chrome.sidebar.scroll;
    try send(session, .{ .scroll = .{ .x = sidebar.x + 1, .y = sidebar.y + 1, .delta_y = 100, .precise = true, .phase = .cancel } });
    try std.testing.expectEqual(offset, gui.chrome.sidebar.scroll);
    try std.testing.expectEqual(@as(f64, 0), gui.widgets.sidebar_scroll_remainder);
}

test "accessibility range edits reject stale text revisions instead of overwriting intervening typing" {
    const session = try initSession();
    defer session.deinit();
    const gui = session.gui;
    gui.app.model.name_prompt.begin(.{ .rename_tab = .{ .tab_id = Session.location.tab_id, .label = "abc" } });
    try publish(session);
    const target = try editorTarget(session, .name);
    var tree: native.AccessibilityTree = .{};
    try std.testing.expect(gui.widgetAccessibility(&tree));
    const revision = tree.nodes.?[0].text_revision;
    try send(session, .{ .text = .{ .bytes = "d" } });
    try send(session, .{ .accessibility = .{ .target_id = target.id.target_id, .generation = target.id.generation, .revision = revision, .action = .replace_range, .replacement_start = 0, .replacement_end = 1, .text = "x" } });
    try std.testing.expectEqualStrings("abcd", gui.app.model.name_prompt.currentConst().?.field.text());
    try std.testing.expect(gui.widgetAccessibility(&tree));
    try send(session, .{ .accessibility = .{ .target_id = target.id.target_id, .generation = target.id.generation, .revision = tree.nodes.?[0].text_revision, .action = .replace_range, .replacement_start = 0, .replacement_end = 1, .text = "x" } });
    try std.testing.expectEqualStrings("xbcd", gui.app.model.name_prompt.currentConst().?.field.text());
}

test "accessibility widget focus cancels terminal prefix without transferring its physical release" {
    const session = try initSession();
    defer session.deinit();
    const gui = session.gui;
    try publish(session);
    try send(session, .{ .key = .{ .code = .{ .char = .init("b") }, .mods = .{ .ctrl = true }, .physical = .{ .value = 31 } } });
    try std.testing.expect(gui.input.router.prefixPending());
    gui.app.model.name_prompt.begin(.{ .rename_tab = .{ .tab_id = Session.location.tab_id, .label = "name" } });
    try publish(session);
    const target = try editorTarget(session, .name);
    try send(session, .{ .accessibility = .{ .target_id = target.id.target_id, .generation = target.id.generation, .action = .focus } });
    try std.testing.expect(!gui.input.router.prefixPending());
    try send(session, .{ .text = .{ .bytes = "x" } });
    try send(session, .{ .key = .{ .code = .{ .char = .init("b") }, .mods = .{ .ctrl = true }, .physical = .{ .value = 31 }, .phase = .release } });
    try std.testing.expectEqualStrings("namex", gui.app.model.name_prompt.currentConst().?.field.text());
    try std.testing.expectEqual(@as(usize, 0), gui.widgets.dispatcher.keys.len);
    try std.testing.expectEqual(@as(usize, 0), gui.input.router.leases.len);
    try gui.focus(false);
    try gui.focus(true);
    _ = try client.controllers.name_prompts.handleInput(&gui.app, .{ .command = .cancel });
    try publish(session);
    try send(session, .{ .text = .{ .bytes = "c" } });
    try session.settle();
    try std.testing.expectEqualStrings("c", session.input[0..session.input_len]);
}

fn promptControl(session: *Session, label: []const u8) !Target {
    const registry = session.gui.widgets.dispatcher.maps.presented();
    for (registry.targets[0..registry.len]) |target| {
        if (std.mem.eql(u8, label, target.label[0..target.label_len])) {
            return target;
        }
    }

    return error.MissingControl;
}

fn click(session: *Session, target: Target) !void {
    try send(session, .{ .pointer = .{ .kind = .press, .x = target.bounds.x + 1, .y = target.bounds.y + 1 } });
    try send(session, .{ .pointer = .{ .kind = .release, .x = target.bounds.x + 1, .y = target.bounds.y + 1 } });
}

test "context actions require an enabled delivered button and release inside its bounds" {
    const session = try initSession();
    defer session.deinit();
    const gui = session.gui;
    gui.app.model.name_prompt.begin(.create_workspace);
    try publish(session);
    const create = try promptControl(session, "Create context");
    try std.testing.expect(!create.enabled);
    try click(session, create);
    try std.testing.expect(gui.app.model.name_prompt.active());
    const cancel = try promptControl(session, "Cancel");
    const name = try editorTarget(session, .name);
    try send(session, .{ .pointer = .{ .kind = .press, .x = cancel.bounds.x + 1, .y = cancel.bounds.y + 1 } });
    try std.testing.expect(gui.app.model.name_prompt.active());
    try std.testing.expect(name.id.eql(gui.widgets.dispatcher.focused.?));
    try send(session, .{ .pointer = .{ .kind = .release, .x = 0, .y = 0 } });
    try std.testing.expect(gui.app.model.name_prompt.active());
    try click(session, cancel);
    try std.testing.expect(!gui.app.model.name_prompt.active());
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
}

test "context folder clicks complete without submitting and reject stale listings" {
    const session = try initSession();
    defer session.deinit();
    const gui = session.gui;
    gui.app.path_completion_runner = .{ .context = session, .start_fn = ignorePathCompletion };
    gui.app.model.name_prompt.begin(.create_workspace);
    _ = gui.app.model.name_prompt.apply(.tab);
    _ = gui.app.model.name_prompt.apply(.{ .insert = "/work/te" });
    _ = gui.app.path_completions.want("/work/te");
    var result: client.PathCompletionResult = .{};
    try result.setBase("/work");
    try result.append("telar");
    try result.append("tests");
    gui.app.model.path_completion.begin();
    gui.app.model.path_completion.expect(@enumFromInt(1));
    try std.testing.expect(gui.app.model.path_completion.apply(@enumFromInt(1), .{ .query = "/work/te", .result = &result }));
    try publish(session);
    const folder = try promptControl(session, "tests");
    try click(session, folder);
    try std.testing.expect(gui.app.model.name_prompt.active());
    try std.testing.expectEqualStrings("/work/tests/", gui.app.model.name_prompt.currentConst().?.directory.text());
    gui.app.model.name_prompt.replaceDirectory("/different/");
    gui.app.model.path_completion.invalidate();
    try click(session, folder);
    try std.testing.expectEqualStrings("/different/", gui.app.model.name_prompt.currentConst().?.directory.text());
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
}

fn ignorePathCompletion(_: *anyopaque, _: client.PathCompletionJob) !void {}

test "context controls reject retired generations and expose native press actions" {
    const session = try initSession();
    defer session.deinit();
    const gui = session.gui;
    gui.app.model.name_prompt.begin(.create_workspace);
    try publish(session);
    const cancel = try promptControl(session, "Cancel");
    var tree: native.AccessibilityTree = .{};
    try std.testing.expect(gui.widgetAccessibility(&tree));
    var found = false;
    for (tree.nodes.?[0..tree.count]) |node| {
        if (node.id == cancel.id.target_id) {
            found = true;
            try std.testing.expect(node.actions & 1 != 0);
        }
    }
    try std.testing.expect(found);
    gui.app.model.name_prompt.begin(.create_workspace);
    try send(session, .{ .accessibility = .{ .target_id = cancel.id.target_id, .generation = cancel.id.generation, .action = .press } });
    try std.testing.expect(gui.app.model.name_prompt.active());
    try publish(session);
    const current = try promptControl(session, "Close new context");
    try send(session, .{ .accessibility = .{ .target_id = current.id.target_id, .generation = current.id.generation, .action = .press } });
    try std.testing.expect(!gui.app.model.name_prompt.active());
}

test "context field padding shares exact pointer and native caret geometry" {
    const session = try initSession();
    defer session.deinit();
    const gui = session.gui;
    gui.app.model.name_prompt.begin(.create_workspace);
    _ = gui.app.model.name_prompt.apply(.{ .insert = "abc界" });
    try publish(session);
    const target = try editorTarget(session, .name);
    const geometry = gui.widgets.editors.presented().find(target.id).?;
    try std.testing.expect(geometry.bounds.x > target.bounds.x);
    try std.testing.expect(geometry.bounds.y > target.bounds.y);
    try send(session, .{ .pointer = .{ .kind = .press, .x = geometry.bounds.x + geometry.cell_width * 2, .y = geometry.bounds.y + 1 } });
    try send(session, .{ .pointer = .{ .kind = .release, .x = geometry.bounds.x + geometry.cell_width * 2, .y = geometry.bounds.y + 1 } });
    try std.testing.expectEqual(@as(usize, 2), gui.app.model.name_prompt.currentConst().?.field.head);
    var context: native.TextContext = .{};
    try std.testing.expect(gui.widgetTextContext(&context));
    try std.testing.expectApproxEqAbs(geometry.bounds.x + geometry.cell_width * 2, context.x, 0.01);
    try send(session, .{ .composition = .{ .target_id = target.id.target_id, .generation = target.id.generation, .text = "é", .selection_start = 2, .selection_end = 2 } });
    try std.testing.expect(gui.widgetTextContext(&context));
    try std.testing.expectApproxEqAbs(geometry.bounds.x + geometry.cell_width * 3, context.x, 0.01);
    try send(session, .{ .text = .{ .target_id = target.id.target_id, .generation = target.id.generation, .bytes = "é" } });
    try std.testing.expectEqualStrings("abéc界", gui.app.model.name_prompt.currentConst().?.field.text());
}

test "context folder scrolling accumulates precise deltas and clamps at the last entry" {
    const session = try initSession();
    defer session.deinit();
    const gui = session.gui;
    gui.app.model.name_prompt.begin(.create_workspace);
    _ = gui.app.model.name_prompt.apply(.tab);
    var result: client.PathCompletionResult = .{};
    for ([_][]const u8{ "api", "dashboard", "docs", "mobile", "platform", "web" }) |name| {
        try result.append(name);
    }
    gui.app.model.path_completion.begin();
    gui.app.model.path_completion.expect(@enumFromInt(1));
    try std.testing.expect(gui.app.model.path_completion.apply(@enumFromInt(1), .{ .query = "/work/", .result = &result }));
    try publish(session);
    const row = try promptControl(session, "api");
    const scroll_event: @import("../input/ScrollEvent.zig") = .{ .x = row.bounds.x + 1, .y = row.bounds.y + 1, .delta_y = row.bounds.height * 0.6, .precise = true };
    try send(session, .{ .scroll = scroll_event });
    try std.testing.expectEqual(@as(u16, 0), gui.app.model.name_prompt.currentConst().?.selection());
    try send(session, .{ .scroll = scroll_event });
    try std.testing.expectEqual(@as(u16, 1), gui.app.model.name_prompt.currentConst().?.selection());
    try send(session, .{ .scroll = .{ .x = row.bounds.x + 1, .y = row.bounds.y + 1, .delta_y = 10000 } });
    try std.testing.expectEqual(@as(u16, 5), gui.app.model.name_prompt.currentConst().?.selection());
    try publish(session);
    _ = try promptControl(session, "web");
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
}

fn tabTarget(session: *Session, tab_id: core.TabId) !Target {
    const registry = session.gui.widgets.dispatcher.maps.presented();
    for (registry.targets[0..registry.len]) |target| {
        if (target.action == .intent and target.action.intent == .select_tab and target.action.intent.select_tab == tab_id) {
            return target;
        }
    }

    return error.MissingTab;
}

fn addDragTabs(session: *Session) !void {
    const model = &session.gui.app.model;
    for (2..4) |id| {
        _ = try model.createTab(.{ .created = .{ .location = .{ .workspace = Session.location.workspace, .tab_id = @enumFromInt(id) }, .position = @intCast(id - 1), .label = "tab", .root_pane_id = @enumFromInt(id * 10) }, .size = model.hostSize() });
    }
    _ = client.request_lifecycle.consume(&session.gui.app, @enumFromInt(3));
    try publish(session);
}

test "native tab drag sends one anchored move after release and waits for runtime order" {
    const session = try initSession();
    defer session.deinit();
    try addDragTabs(session);
    const third: core.TabId = @enumFromInt(3);
    const source = try tabTarget(session, third);
    const target = try tabTarget(session, Session.location.tab_id);
    const y = source.bounds.y + source.bounds.height / 2;
    try send(session, .{ .pointer = .{ .kind = .press, .x = source.bounds.x + 10, .y = y } });
    try send(session, .{ .pointer = .{ .kind = .drag, .x = target.bounds.x + 2, .y = y } });
    try std.testing.expectEqual(@as(?usize, 2), session.gui.app.model.workspace.indexOf(third));
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
    try std.testing.expectEqual(Session.location.tab_id, session.gui.widgets.tab_drag.destination.?.relative_to.?);
    const size = try session.gui.measure(&session.renderer, .{ .width = 800, .height = 600, .scale = 1 });
    try session.gui.resize(size, session.renderer.theme);
    try publish(session);
    try std.testing.expect(session.gui.widgets.tab_drag.source != null);
    const lifted = try tabTarget(session, third);
    try std.testing.expect(lifted.bounds.y < source.bounds.y);
    try std.testing.expect(lifted.bounds.x < source.bounds.x);
    try send(session, .{ .pointer = .{ .kind = .drag, .x = target.bounds.x + 2, .y = y } });
    try std.testing.expectEqual(Session.location.tab_id, session.gui.widgets.tab_drag.destination.?.relative_to.?);
    const failed = try session.gui.prepare(&session.renderer);
    try session.gui.complete(failed, false);
    try send(session, .{ .pointer = .{ .kind = .release, .x = target.bounds.x + 2, .y = y } });
    _ = try session.gui.pump();
    const request = (try core.decodeClient(session.pending.?)).move_tab;
    try std.testing.expectEqual(third, request.location.tab_id);
    try std.testing.expectEqual(Session.location.tab_id, request.relative_to.?);
    try std.testing.expectEqual(core.TabMoveDirection.previous, request.direction);
    try std.testing.expectEqual(@as(?usize, 2), session.gui.app.model.workspace.indexOf(third));
    try session.settle();
    _ = try client.controllers.tab_moves.apply(&session.gui.app, .{ .request_id = request.request_id, .location = request.location, .position = 0 });
    try std.testing.expectEqual(@as(?usize, 0), session.gui.app.model.workspace.indexOf(third));
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
}

test "native tab drag cancels on Escape focus loss and outside drops without pane input" {
    const session = try initSession();
    defer session.deinit();
    try addDragTabs(session);
    const source = try tabTarget(session, @enumFromInt(3));
    const target = try tabTarget(session, Session.location.tab_id);
    const y = source.bounds.y + source.bounds.height / 2;
    const cancellations = [_]Event{ .{ .key = .{ .code = .escape } }, .{ .focus = false }, .{ .pointer = .{ .kind = .drag, .x = 500, .y = 200 } } };
    for (cancellations) |cancel| {
        try session.gui.focus(true);
        try send(session, .{ .pointer = .{ .kind = .press, .x = source.bounds.x + 10, .y = y } });
        try send(session, .{ .pointer = .{ .kind = .drag, .x = target.bounds.x + 2, .y = y } });
        if (cancel == .focus) {
            try session.gui.focus(cancel.focus);
        } else {
            try send(session, cancel);
        }
        try send(session, .{ .pointer = .{ .kind = .release, .x = 500, .y = 200 } });
        try session.settle();
        try std.testing.expectEqual(@as(usize, 0), session.input_len);
        try std.testing.expectEqual(@as(?usize, 2), session.gui.app.model.workspace.indexOf(@enumFromInt(3)));
        try std.testing.expect(!client.request_lifecycle.has(&session.gui.app, .tab_operation));
    }
}
