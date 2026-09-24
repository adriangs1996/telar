const thread_scroll = @import("../widgets/interaction/thread_scroll.zig");
const ClipboardResult = @import("../input/ClipboardResult.zig");
const event_module = @import("../input/event.zig");
const data = @import("model");
const input_support = @import("input_support.zig");
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const thread_items = @import("../widgets/interaction/thread_items.zig");
const Dispatcher = @import("../widgets/interaction/Dispatcher.zig");
const Target = @import("../widgets/interaction/Target.zig");
const Session = @import("Session.zig");
const native = @import("../native/native.zig");
const routing = @import("../widgets/interaction/routing.zig");
const TextInput = @import("../input/TextInput.zig");
const ScrollEvent = @import("../input/ScrollEvent.zig");
const ComposerSelector = @import("../widgets/interaction/ComposerSelector.zig");
const Canvas = @import("../widgets/Canvas.zig");
const ThreadPane = @import("../widgets/ThreadPane.zig");
const animate = @import("animate");
const FrameClock = animate.FrameClock;

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
    const token = try session.draw();
    try input_support.presented(
        session.gui,
        token,
        true,
    );
    try session.settle();
}

fn settleConversationScroll(session: *Session) !void {
    var now_ns: u64 = 0;
    for (session.gui.widgets.thread_scroll.entries[0..session.gui.widgets.thread_scroll.len]) |entry| {
        now_ns = @max(now_ns, entry.motion.timestamp_ns);
    }

    try thread_scroll.advance(session.gui, now_ns + std.time.ns_per_s);
}

fn initSession() !*Session {
    const session = try Session.init();
    errdefer session.deinit();
    try session.bootstrap();
    const size = try session.gui.resizeViewport(
        .{
            .width = 800,
            .height = 600,
            .scale = 1,
        },
    );
    try session.gui.resize(size, session.gui.renderer.theme);
    session.gui.pointer.configure(session.gui.renderer.origin, size);
    try session.settle();
    return session;
}

fn send(session: *Session, event: event_module.Event) !void {
    try input_support.accept(session.gui, event);
    try input_support.pump(session.gui);
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
    try input_support.accept(gui, .{ .composition = .{ .target_id = target.id.target_id, .generation = target.id.generation, .text = &bytes, .selection_start = 2, .selection_end = 2 } });
    @memset(&bytes, 'z');
    try input_support.pump(gui);
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
    _ = try client.name_prompt.inputPrompt(
        &gui.app,
        .{
            .command = .select_all,
        },
    );
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
    const value: TextInput = .{ .bytes = "x", .physical = .{ .value = 25 }, .target_id = 9, .generation = 2 };
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
    var field: data.GenericField(8) = .init("a界b");
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
    for ([_]ClipboardResult.Status{ .unavailable, .cancelled, .success }) |status| {
        _ = try client.name_prompt.inputPrompt(
            &gui.app,
            .{
                .command = .select_all,
            },
        );
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
    _ = try client.name_prompt.inputPrompt(
        &gui.app,
        .{
            .command = .select_all,
        },
    );
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

    _ = try client.name_prompt.inputPrompt(
        &gui.app,
        .{
            .command = .select_all,
        },
    );
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
    const visible = gui.app.model.sidebar_visible;
    gui.app.model.name_prompt.begin(.{ .rename_tab = .{ .tab_id = Session.location.tab_id, .label = "modal" } });
    try send(session, .{ .pointer = .{ .kind = .press, .x = target.bounds.x + 1, .y = target.bounds.y + 1 } });
    try send(session, .{ .pointer = .{ .kind = .release, .x = target.bounds.x + 1, .y = target.bounds.y + 1 } });
    try send(session, .{ .accessibility = .{ .target_id = target.id.target_id, .generation = target.id.generation, .action = .press } });
    try std.testing.expectEqual(visible, gui.app.model.sidebar_visible);
    try std.testing.expectEqualStrings("modal", gui.app.model.name_prompt.currentConst().?.field.text());
}

test "extreme wheel deltas and cancellation keep sidebar scroll state finite" {
    const session = try initSession();
    defer session.deinit();
    const gui = session.gui;
    try publish(session);
    const sidebar = gui.chrome.presented().sidebar_regions.agents;
    try std.testing.expect(sidebar.width > 0);
    try send(session, .{ .scroll = .{ .x = sidebar.x + 1, .y = sidebar.y + 1, .delta_y = std.math.floatMax(f64), .phase = .begin } });
    try std.testing.expect(std.math.isFinite(gui.chrome.sidebar.agents.remainder));
    try send(session, .{ .scroll = .{ .x = sidebar.x + 1, .y = sidebar.y + 1, .delta_y = 0.25, .precise = true, .phase = .update } });
    try std.testing.expectEqual(@as(f64, 0.25), gui.chrome.sidebar.agents.remainder);
    const offset = gui.chrome.sidebar.agents.scroll;
    try send(session, .{ .scroll = .{ .x = sidebar.x + 1, .y = sidebar.y + 1, .delta_y = 100, .precise = true, .phase = .cancel } });
    try std.testing.expectEqual(offset, gui.chrome.sidebar.agents.scroll);
    try std.testing.expectEqual(@as(f64, 0), gui.chrome.sidebar.agents.remainder);
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
    try std.testing.expect(gui.router.prefixPending());
    gui.app.model.name_prompt.begin(.{ .rename_tab = .{ .tab_id = Session.location.tab_id, .label = "name" } });
    try publish(session);
    const target = try editorTarget(session, .name);
    try send(session, .{ .accessibility = .{ .target_id = target.id.target_id, .generation = target.id.generation, .action = .focus } });
    try std.testing.expect(!gui.router.prefixPending());
    try send(session, .{ .text = .{ .bytes = "x" } });
    try send(session, .{ .key = .{ .code = .{ .char = .init("b") }, .mods = .{ .ctrl = true }, .physical = .{ .value = 31 }, .phase = .release } });
    try std.testing.expectEqualStrings("namex", gui.app.model.name_prompt.currentConst().?.field.text());
    try std.testing.expectEqual(@as(usize, 0), gui.widgets.dispatcher.keys.len);
    try std.testing.expectEqual(@as(usize, 0), gui.router.leases.len);
    try input_support.focus(gui, false);
    try input_support.focus(gui, true);
    _ = try client.name_prompt.inputPrompt(
        &gui.app,
        .{
            .command = .cancel,
        },
    );
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
    gui.job_hook = .{
        .context = session,
        .start = ignorePathCompletion,
    };
    gui.app.model.name_prompt.begin(.create_workspace);
    _ = gui.app.model.name_prompt.apply(.tab);
    _ = gui.app.model.name_prompt.apply(.{ .insert = "/work/te" });
    var result: data.PathCompletionResult = .{};
    try result.setBase("/work");
    try result.append("telar");
    try result.append("tests");
    gui.app.model.path_completion.begin();
    _ = gui.app.model.path_completion.want("/work/te");
    gui.app.model.path_completion.land(.{ .query = "/work/te", .result = &result });
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

fn ignorePathCompletion(context: *anyopaque, job: client.Job) !void {
    if (job == .path_completion) {
        return;
    }

    try Session.startJob(context, job);
}

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
    var result: data.PathCompletionResult = .{};
    for ([_][]const u8{ "api", "dashboard", "docs", "mobile", "platform", "web" }) |name| {
        try result.append(name);
    }
    gui.app.model.path_completion.begin();
    gui.app.model.path_completion.land(.{ .query = "/work/", .result = &result });
    try publish(session);
    const row = try promptControl(session, "api");
    const scroll_event: ScrollEvent = .{ .x = row.bounds.x + 1, .y = row.bounds.y + 1, .delta_y = row.bounds.height * 0.6, .precise = true };
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
        _ = try model.createTab(.{ .created = .{ .location = .{ .workspace = Session.location.workspace, .tab_id = @enumFromInt(id) }, .position = @intCast(id - 1), .label = "tab", .root_pane_id = @enumFromInt(id * 10) }, .size = model.host.host_size });
    }
    _ = session.gui.app.model.request_lifecycle.tracker.take(@enumFromInt(3));
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
    try std.testing.expectEqual(@as(?usize, 2), session.gui.app.model.tabs.find(third));
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
    try std.testing.expectEqual(Session.location.tab_id, session.gui.widgets.tab_drag.destination.?.relative_to.?);
    const size = try session.gui.resizeViewport(
        .{
            .width = 800,
            .height = 600,
            .scale = 1,
        },
    );
    try session.gui.resize(size, session.gui.renderer.theme);
    try publish(session);
    try std.testing.expect(session.gui.widgets.tab_drag.source != null);
    const lifted = try tabTarget(session, third);
    try std.testing.expect(lifted.bounds.y < source.bounds.y);
    try std.testing.expect(lifted.bounds.x < source.bounds.x);
    try send(session, .{ .pointer = .{ .kind = .drag, .x = target.bounds.x + 2, .y = y } });
    try std.testing.expectEqual(Session.location.tab_id, session.gui.widgets.tab_drag.destination.?.relative_to.?);
    const failed = try session.draw();
    try input_support.presented(
        session.gui,
        failed,
        false,
    );
    try send(session, .{ .pointer = .{ .kind = .release, .x = target.bounds.x + 2, .y = y } });
    _ = try session.gui.update();
    const request = (try core.decodeClient(try session.sent())).move_tab;
    try std.testing.expectEqual(third, request.location.tab_id);
    try std.testing.expectEqual(Session.location.tab_id, request.relative_to.?);
    try std.testing.expectEqual(core.TabMoveDirection.previous, request.direction);
    try std.testing.expectEqual(@as(?usize, 2), session.gui.app.model.tabs.find(third));
    try session.settle();
    _ = try client.runtime_messages.handleServerMessage(
        &session.gui.app,
        .{
            .tab_moved = .{
                .request_id = request.request_id,
                .location = request.location,
                .position = 0,
            },
        },
    );
    try std.testing.expectEqual(@as(?usize, 0), session.gui.app.model.tabs.find(third));
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
}

test "native tab drag cancels on Escape focus loss and outside drops without pane input" {
    const session = try initSession();
    defer session.deinit();
    try addDragTabs(session);
    const source = try tabTarget(session, @enumFromInt(3));
    const target = try tabTarget(session, Session.location.tab_id);
    const y = source.bounds.y + source.bounds.height / 2;
    const cancellations = [_]event_module.Event{ .{ .key = .{ .code = .escape } }, .{ .focus = false }, .{ .pointer = .{ .kind = .drag, .x = 500, .y = 200 } } };
    for (cancellations) |cancel| {
        try input_support.focus(session.gui, true);
        try send(session, .{ .pointer = .{ .kind = .press, .x = source.bounds.x + 10, .y = y } });
        try send(session, .{ .pointer = .{ .kind = .drag, .x = target.bounds.x + 2, .y = y } });
        if (cancel == .focus) {
            try input_support.focus(session.gui, cancel.focus);
        } else {
            try send(session, cancel);
        }
        try send(session, .{ .pointer = .{ .kind = .release, .x = 500, .y = 200 } });
        try session.settle();
        try std.testing.expectEqual(@as(usize, 0), session.input_len);
        try std.testing.expectEqual(@as(?usize, 2), session.gui.app.model.tabs.find(@enumFromInt(3)));
        try std.testing.expect(!session.gui.app.model.request_lifecycle.tracker.has(.tab_operation));
    }
}

fn agentSession() !*Session {
    const session = try initSession();
    errdefer session.deinit();
    const model = &session.gui.app.model;
    try std.testing.expect(model.identifyPane(.{ .request_id = @enumFromInt(1), .pane_id = Session.pane_id, .location = Session.location, .created = false, .kind = .agent, .pane_generation = 77 }));
    try agentSnapshot(session, .ready, null);
    try publish(session);
    return session;
}

fn agentSnapshot(session: *Session, status: core.agent_thread.Status, approval: ?core.AgentApprovalRequest) !void {
    const text = "What is in this project?Here is the project overview.\n```zig\nconst value = 42;\n```";
    var snapshot: core.AgentThreadSnapshot = .{ .pane_id = Session.pane_id, .pane_generation = 77, .revision = 1, .status = status, .item_count = 2, .text_len = text.len, .pending_approval = approval };
    if (session.gui.app.model.agentPane(Session.pane_id).?.agent_thread) |previous| {
        snapshot.revision = previous.revision + 1;
    }

    snapshot.model_count = 2;
    for ([_][]const u8{ "codex-test", "codex-fast" }, snapshot.model_storage[0..2]) |id, *model| {
        @memcpy(model.id[0..id.len], id);
        @memcpy(model.label[0..id.len], id);
        model.id_len = @intCast(id.len);
        model.label_len = @intCast(id.len);
        model.effort_count = 2;
        model.effort_storage[0] = try core.AgentEffort.init("medium");
        model.effort_storage[1] = try core.AgentEffort.init("high");
        model.default_effort = model.effort_storage[0];
    }

    try snapshot.options.setModel("codex-test");
    snapshot.options.effort = try core.AgentEffort.init("medium");
    @memcpy(snapshot.text_storage[0..text.len], text);
    snapshot.item_storage[0] = .{ .identity = 1, .role = .user, .status = .completed, .text_len = 24, .complete = true };
    snapshot.item_storage[1] = .{ .identity = 2, .role = .assistant, .status = .completed, .text_offset = 24, .text_len = text.len - 24, .complete = true };
    var buffer: [65536]u8 = undefined;
    const bytes = try core.encodeAgentThreadSnapshot(&buffer, &snapshot);
    _ = try client.runtime_messages.handleServerMessage(&session.gui.app, try core.decodeServer(bytes));
}

fn linkSnapshot(session: *Session, text: []const u8) !void {
    var snapshot = session.gui.app.model.agentPane(Session.pane_id).?.agent_thread.?.*;
    snapshot.revision += 1;
    snapshot.item_count = 1;
    snapshot.item_storage[0] = .{ .identity = 42, .role = .assistant, .status = .completed, .text_len = @intCast(text.len), .complete = true };
    snapshot.text_len = @intCast(text.len);
    @memcpy(snapshot.text_storage[0..text.len], text);
    try receiveThread(session, &snapshot);
}

fn messageLinkTarget(session: *Session) !Target {
    const registry = session.gui.widgets.dispatcher.maps.presented();
    for (registry.targets[0..registry.len]) |target| {
        if (target.action == .message_link) {
            return target;
        }
    }

    return error.MissingMessageLink;
}

fn hoverMessageLink(session: *Session, target: Target) !void {
    try send(session, .{ .pointer = .{ .kind = .move, .x = target.bounds.x + target.bounds.width / 2, .y = target.bounds.y + target.bounds.height / 2 } });
    try session.settle();
}

fn composerTarget(session: *Session) !Target {
    const registry = session.gui.widgets.dispatcher.maps.presented();
    for (registry.targets[0..registry.len]) |target| {
        if (target.action == .composer) {
            return target;
        }
    }

    return error.MissingComposer;
}

fn composerSelector(session: *Session, kind: @FieldType(ComposerSelector, "kind")) !Target {
    const registry = session.gui.widgets.dispatcher.maps.presented();
    for (registry.targets[0..registry.len]) |target| {
        if (target.action == .composer_selector and target.action.composer_selector.kind == kind) {
            return target;
        }
    }

    return error.MissingComposerSelector;
}

fn pressControl(session: *Session, target: Target) !void {
    try send(session, .{ .pointer = .{ .kind = .press, .x = target.bounds.x + target.bounds.width / 2, .y = target.bounds.y + target.bounds.height / 2 } });
    try send(session, .{ .pointer = .{ .kind = .release, .x = target.bounds.x + target.bounds.width / 2, .y = target.bounds.y + target.bounds.height / 2 } });
}

test "composer model effort and permissions selectors apply real options through keyboard and pointer" {
    const session = try agentSession();
    defer session.deinit();
    try send(session, .{ .key = .{ .code = .tab } });
    try publish(session);
    try std.testing.expectEqual(.composer_selector, std.meta.activeTag(session.gui.widgets.dispatcher.focusedTarget().?.action));
    try send(session, .{ .key = .{ .code = .enter } });
    try publish(session);
    try std.testing.expectEqual(.model, session.gui.widgets.composer_menu.selector.?.kind);
    try send(session, .{ .key = .{ .code = .down } });
    try send(session, .{ .key = .{ .code = .enter } });
    try std.testing.expect(session.gui.widgets.composer_menu.selector == null);
    const pane = session.gui.app.model.agentPane(Session.pane_id).?;
    try std.testing.expectEqualStrings("codex-fast", pane.agentOptions().modelSlice());
    try publish(session);
    try pressControl(session, try composerSelector(session, .effort));
    try publish(session);
    try send(session, .{ .key = .{ .code = .down } });
    try send(session, .{ .key = .{ .code = .enter } });
    try std.testing.expectEqualStrings("high", pane.agentOptions().effort.idSlice());
    try publish(session);
    try pressControl(session, try composerSelector(session, .access));
    try publish(session);
    try send(session, .{ .key = .{ .code = .end } });
    try send(session, .{ .key = .{ .code = .enter } });
    try std.testing.expectEqual(.full_access, pane.agentOptions().access);
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
    try std.testing.expectEqual(@as(usize, 0), session.agent_prompt_count);
}

test "composer menus reject stale draft catalog attachment and retired menu choices" {
    const session = try agentSession();
    defer session.deinit();
    try pressControl(session, try composerSelector(session, .access));
    try publish(session);
    var choice: ?Target = null;
    const registry = session.gui.widgets.dispatcher.maps.presented();
    for (registry.targets[0..registry.len]) |target| {
        if (target.action == .composer_choice and target.action.composer_choice.index == 2) {
            choice = target;
        }
    }

    const stale = choice orelse return error.MissingComposerChoice;
    const pane = session.gui.app.model.agentPane(Session.pane_id).?;
    _ = session.gui.app.model.changeAgentOption(
        Session.pane_id,
        .{
            .effort = try core.AgentEffort.init("high"),
        },
    );
    try send(session, .{ .accessibility = .{ .target_id = stale.id.target_id, .generation = stale.id.generation, .action = .press } });
    try std.testing.expectEqual(.workspace, pane.agentOptions().access);
    try send(session, .{ .key = .{ .code = .escape } });
    try publish(session);
    try pressControl(session, try composerSelector(session, .access));
    try publish(session);
    const opened = session.gui.widgets.composer_menu.generation;
    try agentSnapshot(session, .working, null);
    try publish(session);
    try std.testing.expectEqual(opened, session.gui.widgets.composer_menu.generation);
    try std.testing.expect(session.gui.widgets.composer_menu.selector != null);
    session.gui.app.model.panes.find(Session.pane_id).?.catalog_revision +%= 1;
    try send(session, .{ .key = .{ .code = .enter } });
    try std.testing.expect(session.gui.widgets.composer_menu.selector == null);
    try std.testing.expectEqual(.workspace, pane.agentOptions().access);
    try publish(session);
    const trigger = try composerSelector(session, .model);
    session.gui.app.model.panes.find(Session.pane_id).?.attachment_generation +%= 1;
    try pressControl(session, trigger);
    try std.testing.expect(session.gui.widgets.composer_menu.selector == null);
    try std.testing.expectEqualStrings("codex-test", pane.agentOptions().modelSlice());
}

test "composer popover consumes outside input and reuses warm glyph and quad storage" {
    const session = try agentSession();
    defer session.deinit();
    try pressControl(session, try composerSelector(session, .access));
    try publish(session);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    session.gui.renderer.atlas.?.allocator = failing.allocator();
    session.gui.renderer.quads.allocator = failing.allocator();
    defer session.gui.renderer.atlas.?.allocator = std.testing.allocator;
    defer session.gui.renderer.quads.allocator = std.testing.allocator;
    for (0..3) |_| {
        try publish(session);
    }

    try std.testing.expectEqual(@as(usize, 0), failing.allocated_bytes);
    try send(session, .{ .text = .{ .bytes = "menu input" } });
    try send(session, .{ .paste = "menu paste" });
    try std.testing.expectEqualStrings("", session.gui.app.model.agentPane(Session.pane_id).?.composerSlice());
    try send(session, .{ .pointer = .{ .kind = .press, .x = 1, .y = 1 } });
    try std.testing.expect(session.gui.widgets.composer_menu.selector == null);
    try send(session, .{ .pointer = .{ .kind = .release, .x = 1, .y = 1 } });
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
}

test "composer menus do not inherit held Enter or arrows from the previous editor" {
    const session = try agentSession();
    defer session.deinit();
    try send(session, .{ .key = .{ .code = .enter, .physical = .{ .value = 91 } } });
    try send(session, .{ .key = .{ .code = .down, .physical = .{ .value = 92 } } });
    try pressControl(session, try composerSelector(session, .access));
    try publish(session);
    const selected = session.gui.widgets.composer_menu.selected;
    try send(session, .{ .key = .{ .code = .down, .physical = .{ .value = 92 }, .phase = .repeat } });
    try std.testing.expectEqual(selected, session.gui.widgets.composer_menu.selected);
    try send(session, .{ .key = .{ .code = .enter, .physical = .{ .value = 91 }, .phase = .repeat } });
    try std.testing.expect(session.gui.widgets.composer_menu.selector != null);
    try std.testing.expectEqual(.workspace, session.gui.app.model.agentPane(Session.pane_id).?.agentOptions().access);
    try send(session, .{ .key = .{ .code = .enter, .physical = .{ .value = 91 }, .phase = .release } });
    try send(session, .{ .key = .{ .code = .enter, .physical = .{ .value = 91 } } });
    try std.testing.expect(session.gui.widgets.composer_menu.selector == null);
}

test "composer menu preserves terminal repeats and releases across pane focus changes" {
    const session = try agentSession();
    defer session.deinit();
    const gui = session.gui;
    const tab = gui.app.model.tabs.active;
    const terminal: core.PaneId = @enumFromInt(21);
    try data.pane_split.split(&gui.app.model, tab, .{ .existing_pane = Session.pane_id, .new_pane = terminal, .location = Session.location, .axis = .horizontal, .area = data.workbench.region(&gui.app.model).area });
    _ = gui.app.model.tabs.layout[tab].focusPane(terminal);
    gui.app.model.panes.find(terminal).?.input_modes.kitty_keyboard_flags = 10;
    try publish(session);
    _ = gui.widgets.dispatcher.focus(null);
    try send(session, .{ .key = .{ .code = .enter, .physical = .{ .value = 93 } } });
    try send(session, .{ .text = .{ .bytes = "x", .physical = .{ .value = 94 } } });
    try session.settle();
    const pressed = session.input_len;
    try std.testing.expect(pressed > 0);
    try std.testing.expectEqual(@as(usize, 2), gui.router.leases.len);
    try pressControl(session, try composerSelector(session, .model));
    try publish(session);
    try send(session, .{ .key = .{ .code = .enter, .physical = .{ .value = 93 }, .phase = .repeat } });
    try send(session, .{ .text = .{ .bytes = "x", .physical = .{ .value = 94 }, .phase = .repeat } });
    try session.settle();
    try std.testing.expect(session.input_len > pressed);
    const repeated = session.input_len;
    try std.testing.expect(gui.widgets.composer_menu.selector != null);
    try send(session, .{ .key = .{ .code = .enter, .physical = .{ .value = 93 }, .phase = .release } });
    try send(session, .{ .text = .{ .bytes = "x", .physical = .{ .value = 94 }, .phase = .release } });
    try session.settle();
    try std.testing.expect(session.input_len > repeated);
    try std.testing.expectEqual(@as(usize, 0), gui.widgets.dispatcher.keys.len);
    try std.testing.expectEqual(@as(usize, 0), gui.router.leases.len);
    try std.testing.expectEqual(@as(usize, 0), gui.app.model.input_leases.len);
    try std.testing.expectEqualStrings("", gui.app.model.panes.findConst(Session.pane_id).?.composerSlice());
    try std.testing.expect(gui.widgets.composer_menu.selector != null);
}

test "opening a selector focuses its agent split and closing restores that exact composer" {
    const session = try agentSession();
    defer session.deinit();
    const tab = session.gui.app.model.tabs.active;
    const second: core.PaneId = @enumFromInt(20);
    try data.pane_split.split(&session.gui.app.model, tab, .{ .existing_pane = Session.pane_id, .new_pane = second, .location = Session.location, .axis = .horizontal, .area = data.workbench.region(&session.gui.app.model).area });
    try std.testing.expect(session.gui.app.model.tabs.layout[tab].focusPane(second));
    try publish(session);
    try pressControl(session, try composerSelector(session, .model));
    try std.testing.expectEqual(Session.pane_id, session.gui.app.model.tabs.layout[tab].focused());
    try publish(session);
    try send(session, .{ .key = .{ .code = .escape } });
    try std.testing.expectEqual(Session.pane_id, session.gui.widgets.dispatcher.focusedTarget().?.action.composer);

    try std.testing.expect(session.gui.app.model.identifyPane(.{ .request_id = @enumFromInt(2), .pane_id = second, .location = Session.location, .created = false, .kind = .agent, .pane_generation = 78 }));
    const source = session.gui.app.model.panes.findConst(Session.pane_id).?.agent_thread.?;
    const snapshot = try std.testing.allocator.create(core.AgentThreadSnapshot);
    defer std.testing.allocator.destroy(snapshot);
    snapshot.* = source.*;
    snapshot.pane_id = second;
    snapshot.pane_generation = 78;
    var buffer: [65536]u8 = undefined;
    const bytes = try core.encodeAgentThreadSnapshot(&buffer, snapshot);
    _ = try client.runtime_messages.handleServerMessage(&session.gui.app, try core.decodeServer(bytes));
    try publish(session);
    var trigger: ?Target = null;
    const registry = session.gui.widgets.dispatcher.maps.presented();
    for (registry.targets[0..registry.len]) |target| {
        if (target.action == .composer_selector and target.action.composer_selector.pane_id == second and target.action.composer_selector.kind == .model) {
            trigger = target;
        }
    }

    try pressControl(session, trigger orelse return error.MissingSecondComposerSelector);
    try std.testing.expectEqual(second, session.gui.app.model.tabs.layout[tab].focused());
    try publish(session);
    try send(session, .{ .key = .{ .code = .escape } });
    try std.testing.expectEqual(second, session.gui.widgets.dispatcher.focusedTarget().?.action.composer);
    try send(session, .{ .text = .{ .bytes = "second draft" } });
    try std.testing.expectEqualStrings("second draft", session.gui.app.model.panes.findConst(second).?.composerSlice());
    try std.testing.expectEqualStrings("", session.gui.app.model.panes.findConst(Session.pane_id).?.composerSlice());
}

test "agent composer owns multiline IME editing and submits one complete prompt" {
    const session = try agentSession();
    defer session.deinit();
    const gui = session.gui;
    const target = try composerTarget(session);
    try std.testing.expect(target.id.eql(gui.widgets.dispatcher.focused.?));
    try send(session, .{ .text = .{ .bytes = "first" } });
    try send(session, .{ .key = .{ .code = .enter, .mods = .{ .shift = true } } });
    var before: native.TextContext = .{};
    try std.testing.expect(gui.widgetTextContext(&before));
    try send(session, .{ .composition = .{ .target_id = target.id.target_id, .generation = target.id.generation, .text = "世界", .selection_start = 6, .selection_end = 6 } });
    try std.testing.expectEqualStrings("first\n", gui.app.model.agentPane(Session.pane_id).?.composerSlice());
    try send(session, .{ .text = .{ .target_id = target.id.target_id, .generation = target.id.generation, .bytes = "世界" } });
    try std.testing.expectEqualStrings("first\n世界", gui.app.model.agentPane(Session.pane_id).?.composerSlice());
    var after: native.TextContext = .{};
    try std.testing.expect(gui.widgetTextContext(&after));
    try std.testing.expect(after.y == before.y and after.x > before.x);
    try send(session, .{ .key = .{ .code = .enter } });
    try session.settle();
    try std.testing.expectEqual(@as(usize, 1), session.agent_prompt_count);
    try std.testing.expectEqualStrings("first\n世界", session.agent_prompt[0..session.agent_prompt_len]);
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
    try std.testing.expectEqualStrings("first\n世界", gui.app.model.agentPane(Session.pane_id).?.composerSlice());
}

test "sans composer pointer selection and IME caret use delivered measured advances" {
    const session = try agentSession();
    defer session.deinit();
    try send(session, .{ .text = .{ .bytes = "iiiWWW" } });
    try publish(session);
    const target = try composerTarget(session);
    const geometry = session.gui.widgets.editors.presented().find(target.id).?;
    try std.testing.expectEqual(@as(f32, 1), geometry.cell_width);
    const font = geometry.font orelse return error.MissingComposerFont;
    try std.testing.expect(font.measure("iii") < font.measure("WWW"));
    const x = geometry.bounds.x + @as(f32, @floatFromInt(font.measure("iii")));
    const y = geometry.bounds.y + geometry.line_height / 2;
    try send(session, .{ .pointer = .{ .kind = .press, .x = x + 0.1, .y = y } });
    try send(session, .{ .pointer = .{ .kind = .release, .x = x + 0.1, .y = y } });
    const pane = session.gui.app.model.agentPane(Session.pane_id).?;
    try std.testing.expectEqual(@as(usize, 3), pane.composer.?.field.head);
    var context: native.TextContext = .{};
    try std.testing.expect(session.gui.widgetTextContext(&context));
    try std.testing.expectApproxEqAbs(@as(f64, x), context.x, 0.01);
    try send(session, .{ .composition = .{ .target_id = target.id.target_id, .generation = target.id.generation, .text = "é", .selection_start = 2, .selection_end = 2 } });
    try publish(session);
    try std.testing.expect(session.gui.widgetTextContext(&context));
    try std.testing.expectApproxEqAbs(@as(f64, geometry.bounds.x) + @as(f64, @floatFromInt(font.measure("iiié"))), context.x, 0.01);
    try std.testing.expectEqualStrings("iiiWWW", pane.composerSlice());
    try send(session, .{ .text = .{ .target_id = target.id.target_id, .generation = target.id.generation, .bytes = "é" } });
    try std.testing.expectEqualStrings("iiiéWWW", pane.composerSlice());
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
}

test "composer keeps prefix binding available and consumes stale attachment input" {
    const session = try agentSession();
    defer session.deinit();
    const gui = session.gui;
    const target = try composerTarget(session);
    try send(session, .{ .key = .{ .code = .{ .char = .{ .bytes = .{ 'b', 0, 0, 0 }, .len = 1 } }, .mods = .{ .ctrl = true }, .physical = .{ .value = 44 } } });
    try std.testing.expect(gui.router.prefixPending());
    try send(session, .{ .text = .{ .target_id = target.id.target_id, .generation = target.id.generation, .bytes = "a", .physical = .{ .value = 45 } } });
    try session.settle();
    try std.testing.expectEqual(@as(usize, 1), session.agent_tab_count);
    try std.testing.expectEqualStrings("", gui.app.model.agentPane(Session.pane_id).?.composerSlice());
    try send(session, .{ .text = .{ .target_id = target.id.target_id, .generation = target.id.generation + 1, .bytes = "stale" } });
    try std.testing.expectEqualStrings("", gui.app.model.agentPane(Session.pane_id).?.composerSlice());
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
}

test "agent prefix survives modifier hover and closes its pane after key release" {
    const session = try agentSession();
    defer session.deinit();
    const gui = session.gui;
    const target = try composerTarget(session);
    try send(session, .{ .text = .{ .bytes = "Keep this draft" } });
    try publish(session);
    try send(session, .{ .key = .{ .code = .{ .char = .init("b") }, .mods = .{ .ctrl = true }, .physical = .{ .value = 44 } } });
    try send(session, .{ .key = .{ .code = .{ .char = .init("b") }, .physical = .{ .value = 44 }, .phase = .release } });
    try std.testing.expect(gui.router.prefixPending());

    for ([_]u4{ 4, 0 }) |mods| {
        try send(session, .{ .pointer = .{ .kind = .move, .mods = mods, .x = target.bounds.x + 2, .y = target.bounds.y + 2 } });
        try publish(session);
        try std.testing.expect(gui.router.prefixPending());
        try std.testing.expectEqualStrings("Keep this draft", gui.app.model.agentPane(Session.pane_id).?.composerSlice());
    }

    try send(session, .{ .text = .{ .target_id = target.id.target_id, .generation = target.id.generation, .bytes = "x", .physical = .{ .value = 45 } } });
    try std.testing.expect(!gui.router.prefixPending());
    _ = try gui.update();
    const request = (try core.decodeClient(try session.sent())).close_pane;
    try std.testing.expectEqual(Session.pane_id, request.pane_id);
    try send(session, .{ .text = .{ .target_id = target.id.target_id, .generation = target.id.generation, .bytes = "x", .physical = .{ .value = 45 }, .phase = .release } });
    try session.settle();
    try expectReleasedKeys(session);
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
}

test "hovering the composer preserves conversation control focus and its pending prefix" {
    const session = try agentSession();
    defer session.deinit();
    try activitySnapshot(session);
    const target = try threadItemTarget(session, 42);
    const composer = try composerTarget(session);
    try send(session, .{ .accessibility = .{ .target_id = target.id.target_id, .generation = target.id.generation, .action = .focus } });
    try send(session, .{ .key = .{ .code = .{ .char = .init("b") }, .mods = .{ .ctrl = true } } });
    try send(session, .{ .pointer = .{ .kind = .move, .x = composer.bounds.x + 2, .y = composer.bounds.y + 2 } });
    try std.testing.expect(target.id.eql(session.gui.widgets.dispatcher.focused.?));
    try std.testing.expect(session.gui.router.prefixPending());

    try send(session, .{ .pointer = .{ .kind = .press, .x = composer.bounds.x + 2, .y = composer.bounds.y + 2 } });
    try std.testing.expect(composer.id.eql(session.gui.widgets.dispatcher.focused.?));
    try std.testing.expect(!session.gui.router.prefixPending());
    try send(session, .{ .pointer = .{ .kind = .release, .x = composer.bounds.x + 2, .y = composer.bounds.y + 2 } });
}

test "approval buttons preserve delivered request identity across replacement" {
    const session = try agentSession();
    defer session.deinit();
    var approval: core.AgentApprovalRequest = .{ .id = 11, .kind = .command, .description_len = 12 };
    @memcpy(approval.description[0..12], "zig build\nls");
    try agentSnapshot(session, .blocked, approval);
    try publish(session);
    var button: ?Target = null;
    const registry = session.gui.widgets.dispatcher.maps.presented();
    for (registry.targets[0..registry.len]) |target| {
        if (target.action == .agent_control and target.action.agent_control.kind == .approve) {
            button = target;
        }
    }

    const delivered = button orelse return error.MissingApproval;
    approval.id = 12;
    try agentSnapshot(session, .blocked, approval);
    try send(session, .{ .pointer = .{ .kind = .press, .x = delivered.bounds.x + 1, .y = delivered.bounds.y + 1 } });
    try send(session, .{ .pointer = .{ .kind = .release, .x = delivered.bounds.x + 1, .y = delivered.bounds.y + 1 } });
    try session.settle();
    try std.testing.expectEqual(@as(usize, 0), session.approval_count);
    try publish(session);
    try send(session, .{ .pointer = .{ .kind = .press, .x = delivered.bounds.x + 1, .y = delivered.bounds.y + 1 } });
    try send(session, .{ .pointer = .{ .kind = .release, .x = delivered.bounds.x + 1, .y = delivered.bounds.y + 1 } });
    try session.settle();
    try std.testing.expectEqual(@as(usize, 1), session.approval_count);
    try std.testing.expectEqual(@as(u64, 12), session.last_approval.?.approval_id);
    try std.testing.expect(session.last_approval.?.accept);
}

test "approval review exposes the complete request with bounded scroll and pane clipping" {
    const session = try agentSession();
    defer session.deinit();
    var approval: core.AgentApprovalRequest = .{ .id = 20, .kind = .command, .description_len = 3500 };
    @memset(approval.description[0..approval.description_len], 'x');
    for (0..70) |index| {
        approval.description[index * 50] = '\n';
    }

    try agentSnapshot(session, .blocked, approval);
    try publish(session);
    var review: ?Target = null;
    const registry = session.gui.widgets.dispatcher.maps.presented();
    for (registry.targets[0..registry.len]) |target| {
        if (target.action == .agent_control and target.action.agent_control.kind == .review) {
            review = target;
        }
    }

    const button = review orelse return error.MissingReview;
    try send(session, .{ .pointer = .{ .kind = .press, .x = button.bounds.x + 1, .y = button.bounds.y + 1 } });
    try send(session, .{ .pointer = .{ .kind = .release, .x = button.bounds.x + 1, .y = button.bounds.y + 1 } });
    try publish(session);
    try std.testing.expectEqual(@as(u64, 20), session.gui.widgets.approval_review.?.approval_id);
    var transcript: ?Target = null;
    const delivered = session.gui.widgets.dispatcher.maps.presented();
    for (delivered.targets[0..delivered.len]) |target| {
        if (target.action == .transcript) {
            transcript = target;
        }
    }

    const body = transcript orelse return error.MissingTranscript;
    try std.testing.expect(body.scroll_limit > 10);
    try send(session, .{ .scroll = .{ .x = body.bounds.x + 1, .y = body.bounds.y + 1, .delta_y = 1 } });
    try settleConversationScroll(session);
    try std.testing.expectEqual(body.scroll_limit - 1, session.gui.app.model.agentPane(Session.pane_id).?.transcript_scroll);
    for (session.gui.renderer.quads.items()) |quad| {
        try std.testing.expect(quad.x >= 0 and quad.y >= 0);
        try std.testing.expect(quad.x + quad.width <= @as(f32, @floatFromInt(session.gui.renderer.viewport[0])));
        try std.testing.expect(quad.y + quad.height <= @as(f32, @floatFromInt(session.gui.renderer.viewport[1])));
    }
}

test "composer paste preserves lines while overflow and stale accessibility edits stay atomic" {
    const session = try agentSession();
    defer session.deinit();
    const gui = session.gui;
    const target = try composerTarget(session);
    try send(session, .{ .paste = "one\r\ntwo\n世界" });
    const field = gui.app.model.agentPane(Session.pane_id).?;
    try std.testing.expectEqualStrings("one\ntwo\n世界", field.composerSlice());
    var tree: native.AccessibilityTree = .{};
    try std.testing.expect(gui.widgetAccessibility(&tree));
    var revision: u64 = 0;
    for (tree.nodes.?[0..tree.count]) |node| {
        if (node.id == target.id.target_id) {
            revision = node.text_revision;
        }
    }

    try send(session, .{ .text = .{ .bytes = "!" } });
    try send(session, .{ .accessibility = .{ .target_id = target.id.target_id, .generation = target.id.generation, .revision = revision, .action = .replace_range, .replacement_start = 0, .replacement_end = 3, .text = "stale" } });
    try send(session, .{ .paste = "x" ** 4097 });
    try std.testing.expectEqualStrings("one\ntwo\n世界!", field.composerSlice());
    try session.settle();
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
}

test "agent thread warm drawing allocates no glyph or quad storage and clips small panes" {
    const session = try agentSession();
    defer session.deinit();
    try publish(session);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    session.gui.renderer.atlas.?.allocator = failing.allocator();
    session.gui.renderer.quads.allocator = failing.allocator();
    defer session.gui.renderer.atlas.?.allocator = std.testing.allocator;
    defer session.gui.renderer.quads.allocator = std.testing.allocator;
    for (0..3) |_| {
        try publish(session);
    }

    try std.testing.expectEqual(@as(usize, 0), failing.allocated_bytes);
    session.gui.renderer.atlas.?.allocator = std.testing.allocator;
    session.gui.renderer.quads.allocator = std.testing.allocator;
    for ([_][2]u32{ .{ 180, 240 }, .{ 120, 100 } }) |viewport| {
        const size = try session.gui.resizeViewport(
            .{
                .width = viewport[0],
                .height = viewport[1],
                .scale = 1,
            },
        );
        try session.gui.resize(size, session.gui.renderer.theme);
        session.gui.pointer.configure(session.gui.renderer.origin, size);
        try publish(session);
        session.gui.renderer.quads.clear();
        var canvas: Canvas = .{
            .atlas = &session.gui.renderer.atlas.?,
            .quads = &session.gui.renderer.quads,
            .metrics = session.gui.renderer.metrics,
            .origin = session.gui.renderer.origin,
            .theme = session.gui.app.model.theme,
            .chrome = session.gui.renderer.chrome,
        };
        const thread = client.ThreadView.capture(&session.gui.app.model, null, Session.pane_id).?;
        try (ThreadPane{ .area = data.workbench.region(&session.gui.app.model).area, .thread = thread }).draw(&canvas);
        for (session.gui.renderer.quads.items()) |quad| {
            try std.testing.expect(quad.x >= 0 and quad.y >= 0);
            try std.testing.expect(quad.x + quad.width <= @as(f32, @floatFromInt(session.gui.renderer.viewport[0])));
            try std.testing.expect(quad.y + quad.height <= @as(f32, @floatFromInt(session.gui.renderer.viewport[1])));
        }
    }
}

fn receiveThread(session: *Session, snapshot: *const core.AgentThreadSnapshot) !void {
    var buffer: [128 * 1024]u8 = undefined;
    const bytes = try core.encodeAgentThreadSnapshot(&buffer, snapshot);
    _ = try client.runtime_messages.handleServerMessage(&session.gui.app, try core.decodeServer(bytes));
}

fn activitySnapshot(session: *Session) !void {
    var snapshot = session.gui.app.model.agentPane(Session.pane_id).?.agent_thread.?.*;
    snapshot.revision += 1;
    const output = "$ zig build check\nChecking client boundaries\nCompiling native widgets\nChecking retained resources\nChecking protocol schema\nChecking tool states\nChecking dispatch relationships\nChecking reconnect\nChecking disclosures\nChecking copy\nChecking Markdown\nAll checks passed.\nExit code: 0\n";
    snapshot.item_count = 1;
    snapshot.item_storage[0] = .{ .identity = 42, .role = .tool, .kind = .command, .status = .completed, .text_len = output.len, .complete = true };
    snapshot.text_len = output.len;
    @memcpy(snapshot.text_storage[0..output.len], output);
    try receiveThread(session, &snapshot);
    try publish(session);
    try showAgentWork(session);
}

fn showAgentWork(session: *Session) !void {
    const registry = session.gui.widgets.dispatcher.maps.presented();
    for (registry.targets[0..registry.len]) |target| {
        if (target.action == .thread_item and target.action.thread_item.operation == .toggle_work) {
            try pressControl(session, target);
            try publish(session);
            return;
        }
    }

    return error.MissingAgentWork;
}

fn threadItemTarget(session: *Session, identity: u64) !Target {
    const registry = session.gui.widgets.dispatcher.maps.presented();
    for (registry.targets[0..registry.len]) |target| {
        if (target.action == .thread_item and target.action.thread_item.identity == identity and target.action.thread_item.operation == .toggle) {
            return target;
        }
    }

    return error.MissingThreadItem;
}

test "work disclosure toggles with pointer and keyboard without copying hidden activity" {
    const session = try agentSession();
    defer session.deinit();
    try activitySnapshot(session);
    const registry = session.gui.widgets.dispatcher.maps.presented();
    const header = for (registry.targets[0..registry.len]) |target| {
        if (target.action == .thread_item and target.action.thread_item.operation == .toggle_work) {
            break target;
        }
    } else return error.MissingAgentWork;
    try std.testing.expect(session.gui.widgets.threadExpanded(header.action.thread_item));
    try pressControl(session, header);
    try publish(session);
    try std.testing.expect(!session.gui.widgets.threadExpanded(header.action.thread_item));
    try std.testing.expectError(error.MissingThreadItem, threadItemTarget(session, 42));
    try send(session, .{ .key = .{ .code = .{ .char = .init("c") }, .mods = .{ .super = true } } });
    var request: native.HostRequest = .{};
    try std.testing.expect(!session.gui.host.next(&request));
    try send(session, .{ .key = .{ .code = .enter, .physical = .{ .value = 36 } } });
    try send(session, .{ .key = .{ .code = .enter, .physical = .{ .value = 36 }, .phase = .release } });
    try publish(session);
    try std.testing.expect(session.gui.widgets.threadExpanded(header.action.thread_item));
    _ = try threadItemTarget(session, 42);
    const current = session.gui.widgets.dispatcher.focusedTarget().?;
    try std.testing.expectEqual(.toggle_work, current.action.thread_item.operation);
    try std.testing.expectApproxEqAbs(header.bounds.y, current.bounds.y, 25);
    const pane = session.gui.app.model.panes.find(Session.pane_id).?;
    pane.attachment_generation += 1;
    try send(session, .{ .accessibility = .{ .target_id = current.id.target_id, .generation = current.id.generation, .action = .press } });
    try std.testing.expect(session.gui.widgets.threadExpanded(header.action.thread_item));
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
}

test "conversation disclosures preserve reading position and keyboard focus while copy owns original text" {
    const session = try agentSession();
    defer session.deinit();
    try activitySnapshot(session);
    const target = try threadItemTarget(session, 42);
    try pressControl(session, target);
    try std.testing.expect(session.gui.widgets.threadExpanded(target.action.thread_item));
    try publish(session);
    const expanded = try threadItemTarget(session, 42);
    try std.testing.expectEqual(.thread_item, std.meta.activeTag(session.gui.widgets.dispatcher.focusedTarget().?.action));
    try std.testing.expectApproxEqAbs(target.bounds.y, expanded.bounds.y, 25);
    try send(session, .{ .key = .{ .code = .{ .char = .init("c") }, .mods = .{ .super = true }, .physical = .{ .value = 45 } } });
    var request: native.HostRequest = .{};
    try std.testing.expect(session.gui.host.next(&request));
    const thread = session.gui.app.model.agentPane(Session.pane_id).?.agent_thread.?;
    try std.testing.expectEqualStrings(thread.items()[0].text(thread), request.text.?[0..request.len]);
    try send(session, .{ .key = .{ .code = .{ .char = .init("c") }, .mods = .{ .super = true }, .physical = .{ .value = 45 }, .phase = .repeat } });
    var duplicate: native.HostRequest = .{};
    try std.testing.expect(!session.gui.host.next(&duplicate));
    try std.testing.expect(session.gui.widgets.copied_item == null);
    try send(session, .{ .clipboard = .{ .request_id = request.request_id, .target_id = request.target_id, .generation = request.generation, .operation = .write, .status = .success } });
    try std.testing.expect(session.gui.widgets.copied_item.?.sameItem(target.action.thread_item));
    try send(session, .{ .key = .{ .code = .{ .char = .init("c") }, .mods = .{ .super = true }, .physical = .{ .value = 45 }, .phase = .release } });
    try send(session, .{ .key = .{ .code = .escape } });
    try publish(session);
    try std.testing.expectEqual(.composer, std.meta.activeTag(session.gui.widgets.dispatcher.focusedTarget().?.action));
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
}

test "an evicted conversation item cannot activate a replacement through stale delivery" {
    const session = try agentSession();
    defer session.deinit();
    try activitySnapshot(session);
    const target = try threadItemTarget(session, 42);
    var snapshot = session.gui.app.model.agentPane(Session.pane_id).?.agent_thread.?.*;
    snapshot.revision += 1;
    snapshot.item_storage[0].identity = 99;
    try receiveThread(session, &snapshot);
    try pressControl(session, target);
    try std.testing.expect(!session.gui.widgets.threadExpanded(target.action.thread_item));
    try send(session, .{ .accessibility = .{ .target_id = target.id.target_id, .generation = target.id.generation, .action = .press } });
    try std.testing.expect(!session.gui.widgets.threadExpanded(target.action.thread_item));
    try publish(session);
    try showAgentWork(session);
    const replacement = try threadItemTarget(session, 99);
    try std.testing.expect(!replacement.id.eql(target.id));
    try std.testing.expect(!session.gui.widgets.threadExpanded(replacement.action.thread_item));
    try pressControl(session, replacement);
    try std.testing.expect(session.gui.widgets.threadExpanded(replacement.action.thread_item));
    const pane = session.gui.app.model.panes.find(Session.pane_id).?;
    pane.attachment_generation += 1;
    try send(session, .{ .accessibility = .{ .target_id = replacement.id.target_id, .generation = replacement.id.generation, .action = .press } });
    try std.testing.expect(session.gui.widgets.threadExpanded(replacement.action.thread_item));
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
}

test "copy confirmation expires once and failed native writes never confirm" {
    const session = try agentSession();
    defer session.deinit();
    try activitySnapshot(session);
    const target = try threadItemTarget(session, 42);
    try pressControl(session, target);
    try send(session, .{ .key = .{ .code = .{ .char = .init("c") }, .mods = .{ .super = true } } });
    var request: native.HostRequest = .{};
    try std.testing.expect(session.gui.host.next(&request));
    try send(session, .{ .clipboard = .{ .request_id = request.request_id, .target_id = request.target_id, .generation = request.generation, .operation = .write, .status = .cancelled } });
    try std.testing.expect(session.gui.widgets.copied_item == null);
    session.gui.widgets.copied_item = target.action.thread_item;
    session.gui.widgets.copied_until_ns = 2000;
    var clock: FrameClock = .{};
    clock.begin(1000);
    try std.testing.expect(session.gui.widgets.threadCopied(target.action.thread_item, &clock));
    try std.testing.expectEqual(@as(?u64, 2000), clock.deadline_ns);
    clock.begin(2000);
    try std.testing.expect(!session.gui.widgets.threadCopied(target.action.thread_item, &clock));
    try std.testing.expectEqual(@as(?u64, null), clock.deadline_ns);
}

test "disclosure anchors survive a newer snapshot and failed frame delivery" {
    const session = try agentSession();
    defer session.deinit();
    try activitySnapshot(session);
    const target = try threadItemTarget(session, 42);
    var snapshot = session.gui.app.model.agentPane(Session.pane_id).?.agent_thread.?.*;
    const output = "More streamed tool output\n" ** 48;
    snapshot.revision += 1;
    snapshot.item_storage[0].text_len = output.len;
    snapshot.text_len = output.len;
    @memcpy(snapshot.text_storage[0..output.len], output);
    try receiveThread(session, &snapshot);
    try pressControl(session, target);
    const pane = session.gui.app.model.agentPane(Session.pane_id).?;
    try std.testing.expectEqual(@as(u32, 0), pane.transcript_scroll);
    const failed = try session.draw();
    try std.testing.expectEqual(@as(u32, 0), pane.transcript_scroll);
    try input_support.presented(
        session.gui,
        failed,
        false,
    );
    try std.testing.expectEqual(@as(u32, 0), pane.transcript_scroll);
    try std.testing.expect(session.gui.widgets.thread_anchor.pending != null);
    try publish(session);
    const expanded = try threadItemTarget(session, 42);
    try std.testing.expectApproxEqAbs(target.bounds.y, expanded.bounds.y, 25);
    try std.testing.expect(pane.transcript_scroll > 0);
    try std.testing.expect(session.gui.widgets.thread_anchor.pending == null);
    try std.testing.expectEqual(.thread_item, std.meta.activeTag(session.gui.widgets.dispatcher.focusedTarget().?.action));
}

test "disclosure delivery cannot overwrite newer scrolling or a newer disclosure" {
    const session = try agentSession();
    defer session.deinit();
    try activitySnapshot(session);
    const target = try threadItemTarget(session, 42);
    try pressControl(session, target);
    const first = try session.draw();
    _ = session.gui.app.model.scrollAgentThread(Session.pane_id, 7);
    try input_support.presented(
        session.gui,
        first,
        true,
    );
    try std.testing.expectEqual(@as(u32, 7), session.gui.app.model.agentPane(Session.pane_id).?.transcript_scroll);
    _ = session.gui.app.model.scrollAgentThread(Session.pane_id, 65536);
    try publish(session);
    const baseline = session.gui.app.model.agentPane(Session.pane_id).?.transcript_scroll;
    const expanded = try threadItemTarget(session, 42);
    try pressControl(session, expanded);
    const second = try session.draw();
    try send(session, .{ .accessibility = .{ .target_id = expanded.id.target_id, .generation = expanded.id.generation, .action = .press } });
    const newer = session.gui.widgets.thread_anchor.pending.?.sequence;
    try input_support.presented(
        session.gui,
        second,
        true,
    );
    try std.testing.expectEqual(newer, session.gui.widgets.thread_anchor.pending.?.sequence);
    try std.testing.expectEqual(baseline, session.gui.app.model.agentPane(Session.pane_id).?.transcript_scroll);
    try publish(session);
    try std.testing.expect(session.gui.widgets.thread_anchor.pending == null);
    const latest = try threadItemTarget(session, 42);
    try pressControl(session, latest);
    const third = try session.draw();
    try send(session, .{ .key = .{ .code = .page_down } });
    const manual = session.gui.app.model.agentPane(Session.pane_id).?.transcript_scroll;
    try std.testing.expect(session.gui.widgets.thread_anchor.pending == null);
    try input_support.presented(
        session.gui,
        third,
        true,
    );
    try std.testing.expectEqual(manual, session.gui.app.model.agentPane(Session.pane_id).?.transcript_scroll);
}

test "folded work retires obsolete scroll only after successful frame delivery" {
    const session = try agentSession();
    defer session.deinit();
    try activitySnapshot(session);
    const item = try threadItemTarget(session, 42);
    try pressControl(session, item);
    try publish(session);
    const pane = session.gui.app.model.agentPane(Session.pane_id).?;
    try std.testing.expect(pane.transcript_scroll > 0);
    try showAgentWork(session);
    try std.testing.expectEqual(@as(u32, 0), pane.transcript_scroll);

    // Restore an obsolete offset, as input against older geometry can do.
    _ = session.gui.app.model.scrollAgentThread(pane.id, 100);
    const failed = try session.draw();
    try input_support.presented(
        session.gui,
        failed,
        false,
    );
    try std.testing.expectEqual(@as(u32, 100), pane.transcript_scroll);
    try publish(session);
    try std.testing.expectEqual(@as(u32, 0), pane.transcript_scroll);
    try publish(session);
    try std.testing.expectEqual(@as(u32, 0), pane.transcript_scroll);
}

test "scrolling during work collapse cannot retain the expanded scroll extent" {
    const session = try agentSession();
    defer session.deinit();
    try activitySnapshot(session);
    try pressControl(session, try threadItemTarget(session, 42));
    try publish(session);
    const pane = session.gui.app.model.agentPane(Session.pane_id).?;
    try std.testing.expect(pane.transcript_scroll > 0);
    const registry = session.gui.widgets.dispatcher.maps.presented();
    const header = for (registry.targets[0..registry.len]) |target| {
        if (target.action == .thread_item and target.action.thread_item.operation == .toggle_work) {
            break target;
        }
    } else return error.MissingAgentWork;

    try pressControl(session, header);
    const collapsing = try session.draw();
    try send(session, .{ .scroll = .{ .x = header.bounds.x + 1, .y = header.bounds.y + 1, .delta_y = -1 } });
    const manual = pane.transcript_scroll;
    try std.testing.expect(manual > 0);
    try std.testing.expect(session.gui.widgets.thread_anchor.pending == null);
    try input_support.presented(
        session.gui,
        collapsing,
        true,
    );
    try std.testing.expectEqual(manual, pane.transcript_scroll);
    try publish(session);
    try std.testing.expectEqual(@as(u32, 0), pane.transcript_scroll);
}

test "an empty conversation clears scroll even when no previous row survives" {
    const session = try agentSession();
    defer session.deinit();
    try activitySnapshot(session);
    try pressControl(session, try threadItemTarget(session, 42));
    try publish(session);
    const pane = session.gui.app.model.agentPane(Session.pane_id).?;
    const previous = pane.transcript_scroll;
    try std.testing.expect(previous > 0);
    var snapshot = pane.agent_thread.?.*;
    snapshot.revision += 1;
    snapshot.item_count = 0;
    snapshot.text_len = 0;
    try receiveThread(session, &snapshot);
    const failed = try session.draw();
    try input_support.presented(
        session.gui,
        failed,
        false,
    );
    try std.testing.expectEqual(previous, pane.transcript_scroll);
    try publish(session);
    try std.testing.expectEqual(@as(u32, 0), pane.transcript_scroll);
}

test "conversation controls focus their pane and stale controls cannot focus a replacement" {
    const session = try agentSession();
    defer session.deinit();
    try activitySnapshot(session);
    const tab = session.gui.app.model.tabs.active;
    const second: core.PaneId = @enumFromInt(22);
    try data.pane_split.split(&session.gui.app.model, tab, .{ .existing_pane = Session.pane_id, .new_pane = second, .location = Session.location, .axis = .horizontal, .area = data.workbench.region(&session.gui.app.model).area });
    _ = session.gui.app.model.tabs.layout[tab].focusPane(second);
    try publish(session);
    const target = try threadItemTarget(session, 42);
    try pressControl(session, target);
    try std.testing.expectEqual(Session.pane_id, session.gui.app.model.tabs.layout[tab].focused());
    _ = session.gui.app.model.tabs.layout[tab].focusPane(second);
    var snapshot = session.gui.app.model.agentPane(Session.pane_id).?.agent_thread.?.*;
    snapshot.revision += 1;
    snapshot.item_storage[0].identity = 43;
    try receiveThread(session, &snapshot);
    try send(session, .{ .accessibility = .{ .target_id = target.id.target_id, .generation = target.id.generation, .action = .focus } });
    try std.testing.expectEqual(second, session.gui.app.model.tabs.layout[tab].focused());
}

fn adoptAgentBinding(session: *Session, binding: data.config_values.ConfiguredBinding) void {
    session.gui.adoptBindings(
        .{
            .prefix = data.keybind.default_prefix,
            .bindings = &.{
                binding,
            },
            .escape_timeout_ns = std.time.ns_per_s,
            .sequence_timeout_ns = std.time.ns_per_hour,
        },
    );
}

fn expectReleasedKeys(session: *Session) !void {
    try std.testing.expectEqual(@as(usize, 0), session.gui.widgets.dispatcher.keys.len);
    try std.testing.expectEqual(@as(usize, 0), session.gui.router.leases.len);
    try std.testing.expectEqual(@as(usize, 0), session.gui.app.model.input_leases.len);
}

test "agent scroll bindings move the focused transcript without editing the composer" {
    const session = try agentSession();
    defer session.deinit();
    try linkSnapshot(session, "Earlier output\n" ** 80);
    try publish(session);
    const pane = session.gui.app.model.agentPane(Session.pane_id).?;
    const terminal_scroll = pane.scroll;

    try send(
        session,
        .{
            .key = .{
                .code = data.keybind.default_prefix.code,
                .mods = .{
                    .ctrl = true,
                },
                .physical = .{
                    .value = 103,
                },
            },
        },
    );
    try std.testing.expect(session.gui.router.prefixPending());
    try send(
        session,
        .{
            .key = .{
                .code = data.keybind.default_prefix.code,
                .physical = .{
                    .value = 103,
                },
                .phase = .release,
            },
        },
    );
    try send(session, .{ .text = .{ .bytes = "-", .physical = .{ .value = 104 } } });
    try send(session, .{ .text = .{ .bytes = "-", .physical = .{ .value = 104 }, .phase = .release } });
    try settleConversationScroll(session);
    try std.testing.expectEqual(@as(u32, 3), pane.transcript_scroll);
    try publish(session);
    try settleConversationScroll(session);
    try std.testing.expectEqual(@as(u32, 3), pane.transcript_scroll);

    try send(
        session,
        .{
            .key = .{
                .code = data.keybind.default_prefix.code,
                .mods = .{
                    .ctrl = true,
                },
                .physical = .{
                    .value = 103,
                },
            },
        },
    );
    try send(
        session,
        .{
            .key = .{
                .code = data.keybind.default_prefix.code,
                .physical = .{
                    .value = 103,
                },
                .phase = .release,
            },
        },
    );
    try send(session, .{ .text = .{ .bytes = "=", .physical = .{ .value = 105 } } });
    try send(session, .{ .text = .{ .bytes = "=", .physical = .{ .value = 105 }, .phase = .release } });
    try settleConversationScroll(session);
    try std.testing.expectEqual(@as(u32, 0), pane.transcript_scroll);
    try std.testing.expectEqualDeep(terminal_scroll, pane.scroll);
    try std.testing.expectEqualStrings("", pane.composerSlice());
    try session.settle();
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
    try std.testing.expectEqual(@as(usize, 0), session.agent_prompt_count);
    try expectReleasedKeys(session);
}

test "held agent scroll bindings pace transcript movement and stop on release" {
    const session = try agentSession();
    defer session.deinit();
    try linkSnapshot(session, "Earlier output\n" ** 80);
    try publish(session);
    adoptAgentBinding(session, try data.config_values.ConfiguredBinding.parse(&.{"alt+-"}, .{ .scroll_pane = .up }));
    const pane = session.gui.app.model.agentPane(Session.pane_id).?;
    var key: data.Key = .{
        .code = .{
            .char = .init("-"),
        },
        .mods = .{
            .alt = true,
        },
        .physical = .{
            .value = 45,
        },
    };

    _ = try session.gui.routeKey(.{ .key = key, .raw = "", .now_ns = 0 });
    try settleConversationScroll(session);
    try std.testing.expectEqual(@as(u32, 3), pane.transcript_scroll);
    key.phase = .repeat;
    _ = try session.gui.routeKey(.{ .key = key, .raw = "", .now_ns = 99 * std.time.ns_per_ms });
    try settleConversationScroll(session);
    try std.testing.expectEqual(@as(u32, 3), pane.transcript_scroll);
    _ = try session.gui.routeKey(.{ .key = key, .raw = "", .now_ns = 100 * std.time.ns_per_ms });
    try settleConversationScroll(session);
    try std.testing.expectEqual(@as(u32, 6), pane.transcript_scroll);
    key.phase = .release;
    _ = try session.gui.routeKey(.{ .key = key, .raw = "", .now_ns = 200 * std.time.ns_per_ms });
    key.phase = .repeat;
    _ = try session.gui.routeKey(.{ .key = key, .raw = "", .now_ns = 300 * std.time.ns_per_ms });
    try settleConversationScroll(session);
    try std.testing.expectEqual(@as(u32, 6), pane.transcript_scroll);
    try std.testing.expectEqualStrings("", pane.composerSlice());
    try expectReleasedKeys(session);
}

test "agent scroll bindings respect transcript bounds and attachment identity" {
    const session = try agentSession();
    defer session.deinit();
    try linkSnapshot(session, "Earlier output\n" ** 80);
    try publish(session);
    const pane = session.gui.app.model.panes.find(Session.pane_id).?;
    const registry = session.gui.widgets.dispatcher.maps.presented();
    const transcript = for (registry.targets[0..registry.len]) |target| {
        if (target.action == .transcript and target.action.transcript == pane.id) {
            break target;
        }
    } else return error.MissingTranscript;
    try std.testing.expect(transcript.scroll_limit > 3);

    _ = try input_support.action(
        session.gui,
        .{
            .scroll_pane = .down,
        },
    );
    try settleConversationScroll(session);
    try std.testing.expectEqual(@as(u32, 0), pane.transcript_scroll);
    _ = session.gui.app.model.scrollAgentThread(pane.id, transcript.scroll_limit - 1);
    _ = try input_support.action(
        session.gui,
        .{
            .scroll_pane = .up,
        },
    );
    try settleConversationScroll(session);
    try std.testing.expectEqual(transcript.scroll_limit, pane.transcript_scroll);
    _ = try input_support.action(
        session.gui,
        .{
            .scroll_pane = .up,
        },
    );
    try settleConversationScroll(session);
    try std.testing.expectEqual(transcript.scroll_limit, pane.transcript_scroll);

    pane.attached = false;
    try std.testing.expect(client.repeatPolicy(.{ .scroll_pane = .down }, client.actions.repeatPane(&session.gui.app)) == null);
    _ = try input_support.action(
        session.gui,
        .{
            .scroll_pane = .down,
        },
    );
    try settleConversationScroll(session);
    try std.testing.expectEqual(transcript.scroll_limit, pane.transcript_scroll);
    pane.attached = true;
    pane.attachment_generation += 1;
    _ = try input_support.action(
        session.gui,
        .{
            .scroll_pane = .down,
        },
    );
    try settleConversationScroll(session);
    try std.testing.expectEqual(transcript.scroll_limit, pane.transcript_scroll);
    try std.testing.expectEqualStrings("", pane.composerSlice());
}

test "slash completion filters commands and rename submits through the agent request" {
    const session = try agentSession();
    defer session.deinit();
    try send(session, .{ .text = .{ .bytes = "/" } });
    try publish(session);
    try std.testing.expect(session.gui.widgets.completions.open);
    try std.testing.expectEqual(core.AgentCommand.kinds.len, session.gui.widgets.completions.count);
    try send(session, .{ .text = .{ .bytes = "ren" } });
    try publish(session);
    try std.testing.expectEqual(@as(u8, 1), session.gui.widgets.completions.count);
    try send(session, .{ .key = .{ .code = .enter } });
    try std.testing.expectEqualStrings("/rename ", session.gui.app.model.agentPane(Session.pane_id).?.composerSlice());
    try std.testing.expectEqual(@as(usize, 0), session.agent_prompt_count);
    try send(session, .{ .text = .{ .bytes = "Parser work" } });
    try send(session, .{ .key = .{ .code = .enter } });
    try session.settle();
    try std.testing.expectEqual(@as(usize, 1), session.agent_prompt_count);
    try std.testing.expectEqualStrings("/rename Parser work", session.agent_prompt[0..session.agent_prompt_len]);
}

test "skill completion preserves surrounding text and rejects stale clicks" {
    const session = try agentSession();
    defer session.deinit();
    const pane = session.gui.app.model.agentPane(Session.pane_id).?;
    var snapshot = pane.agent_thread.?.*;
    snapshot.revision += 1;
    snapshot.skills = .{ .phase = .ready, .revision = 1 };
    try snapshot.skills.append(.{ .name = "review", .label = "Code Review", .description = "Review the current changes", .scope = .repo });
    try snapshot.skills.append(.{ .name = "release", .description = "Publish a release", .scope = .user });
    try receiveThread(session, &snapshot);
    try send(session, .{ .text = .{ .bytes = "Please $rev" } });
    try publish(session);
    var choice: ?Target = null;
    for (session.gui.widgets.dispatcher.maps.presented().targets[0..session.gui.widgets.dispatcher.maps.presented().len]) |target| {
        if (target.action == .composer_completion) {
            choice = target;
            break;
        }
    }
    try std.testing.expect(choice != null);
    try std.testing.expectEqualStrings("Code Review", choice.?.label[0..choice.?.label_len]);
    try send(session, .{ .key = .{ .code = .tab } });
    try std.testing.expectEqualStrings("Please $review ", pane.composerSlice());
    try std.testing.expectEqual(@as(usize, 0), session.agent_prompt_count);
    try send(session, .{ .accessibility = .{ .target_id = choice.?.id.target_id, .generation = choice.?.id.generation, .action = .press } });
    try std.testing.expectEqualStrings("Please $review ", pane.composerSlice());
    try send(session, .{ .text = .{ .bytes = "the diff" } });
    try send(session, .{ .key = .{ .code = .enter } });
    try session.settle();
    try std.testing.expectEqualStrings("Please $review the diff", session.agent_prompt[0..session.agent_prompt_len]);
}

test "completion escape preserves editor focus and model command opens the existing selector" {
    const session = try agentSession();
    defer session.deinit();
    const composer = try composerTarget(session);
    try send(session, .{ .text = .{ .bytes = "/" } });
    try publish(session);
    try send(session, .{ .key = .{ .code = .down } });
    try std.testing.expectEqual(@as(u8, 1), session.gui.widgets.completions.selected);
    try send(session, .{ .key = .{ .code = .escape } });
    try publish(session);
    try std.testing.expect(!session.gui.widgets.completions.open);
    try std.testing.expect(composer.id.eql(session.gui.widgets.dispatcher.focused.?));
    try send(session, .{ .text = .{ .bytes = "model" } });
    try send(session, .{ .key = .{ .code = .enter } });
    try std.testing.expectEqual(.model, session.gui.widgets.composer_menu.selector.?.kind);
    try std.testing.expectEqualStrings("", session.gui.app.model.agentPane(Session.pane_id).?.composerSlice());
    try std.testing.expectEqual(@as(usize, 0), session.agent_prompt_count);
}

test "slash skill completion consumes held Enter and rejects stale native keys" {
    const session = try agentSession();
    defer session.deinit();
    const pane = session.gui.app.model.agentPane(Session.pane_id).?;
    var snapshot = pane.agent_thread.?.*;
    snapshot.revision += 1;
    snapshot.skills = .{ .phase = .ready, .revision = 1 };
    try snapshot.skills.append(.{ .name = "review" });
    try receiveThread(session, &snapshot);
    try send(session, .{ .text = .{ .bytes = "/skill:rev" } });
    try publish(session);
    try std.testing.expectEqual(@as(u8, 1), session.gui.widgets.completions.count);
    const composer = try composerTarget(session);
    try send(session, .{ .key = .{ .code = .escape, .target_id = composer.id.target_id, .generation = composer.id.generation + 1 } });
    try std.testing.expect(session.gui.widgets.completions.open);
    try send(session, .{ .key = .{ .code = .enter, .physical = .{ .value = 97 } } });
    try std.testing.expectEqualStrings("$review ", pane.composerSlice());
    try send(session, .{ .key = .{ .code = .enter, .physical = .{ .value = 97 }, .phase = .repeat } });
    try send(session, .{ .key = .{ .code = .enter, .physical = .{ .value = 97 }, .phase = .release } });
    try session.settle();
    try std.testing.expectEqual(@as(usize, 0), session.agent_prompt_count);
    try std.testing.expectEqualStrings("$review ", pane.composerSlice());
    try send(session, .{ .key = .{ .code = .enter, .physical = .{ .value = 97 } } });
    try session.settle();
    try std.testing.expectEqual(@as(usize, 1), session.agent_prompt_count);
}

test "a terminal split receives typing while the sibling agent composer stays visible" {
    for ([_]enum { before_frame, after_frame, during_frame }{ .before_frame, .after_frame, .during_frame }) |timing| {
        const session = try agentSession();
        defer session.deinit();
        const gui = session.gui;
        const tab = gui.app.model.tabs.active;
        const token = if (timing == .during_frame) try session.draw() else 0;
        const terminal: core.PaneId = @enumFromInt(21);
        try data.pane_split.split(&gui.app.model, tab, .{ .existing_pane = Session.pane_id, .new_pane = terminal, .location = Session.location, .axis = .horizontal, .area = data.workbench.region(&gui.app.model).area });
        _ = gui.app.model.tabs.layout[tab].focusPane(terminal);
        if (timing == .after_frame) {
            try publish(session);
        } else if (timing == .during_frame) {
            try input_support.presented(
                gui,
                token,
                true,
            );
        }

        try send(session, .{ .text = .{ .bytes = "x" } });
        try session.settle();
        try std.testing.expectEqual(terminal, gui.app.model.tabs.layout[tab].focused());
        try std.testing.expectEqualStrings("", gui.app.model.panes.findConst(Session.pane_id).?.composerSlice());
        try std.testing.expectEqualStrings("x", session.input[0..session.input_len]);
        try std.testing.expectEqual(terminal, session.last_input_pane.?);
        var context: native.TextContext = .{};
        try std.testing.expect(!gui.widgetTextContext(&context));
    }
}

test "leaving an agent pane retires native text context and queued editor input before repaint" {
    const session = try agentSession();
    defer session.deinit();
    const gui = session.gui;
    const target = try composerTarget(session);
    try send(session, .{ .composition = .{ .target_id = target.id.target_id, .generation = target.id.generation, .text = "pending", .selection_start = 7, .selection_end = 7 } });
    const tab = gui.app.model.tabs.active;
    const terminal: core.PaneId = @enumFromInt(21);
    try data.pane_split.split(&gui.app.model, tab, .{ .existing_pane = Session.pane_id, .new_pane = terminal, .location = Session.location, .axis = .horizontal, .area = data.workbench.region(&gui.app.model).area });
    _ = gui.app.model.tabs.layout[tab].focusPane(terminal);
    // Focus moves inside an event; the turn that ran it reconciles widgets.
    _ = try gui.update();
    var context: native.TextContext = .{};
    try std.testing.expect(!gui.widgetTextContext(&context));
    try std.testing.expect(gui.widgets.preedit.owner == null);
    try send(session, .{ .text = .{ .target_id = target.id.target_id, .generation = target.id.generation, .bytes = "late" } });
    try send(session, .{ .text = .{ .target_id = target.id.target_id, .generation = target.id.generation, .bytes = "z", .physical = .{ .value = 120 } } });
    try send(session, .{ .text = .{ .target_id = target.id.target_id, .generation = target.id.generation, .bytes = "z", .physical = .{ .value = 120 }, .phase = .release } });
    try send(session, .{ .paste = "terminal paste" });
    try session.settle();
    try std.testing.expectEqual(terminal, gui.app.model.tabs.layout[tab].focused());
    try std.testing.expectEqualStrings("", gui.app.model.panes.findConst(Session.pane_id).?.composerSlice());
    try std.testing.expectEqualStrings("terminal paste", session.input[0..session.input_len]);
    try std.testing.expectEqual(terminal, session.last_input_pane.?);
    try expectReleasedKeys(session);
}

test "an agent chord timeout cannot restore pane focus before repaint" {
    const session = try agentSession();
    defer session.deinit();
    const gui = session.gui;
    const target = try composerTarget(session);
    adoptAgentBinding(session, try data.config_values.ConfiguredBinding.parse(&.{ "g", "g" }, .toggle_sidebar));
    try send(session, .{ .text = .{ .target_id = target.id.target_id, .generation = target.id.generation, .bytes = "g", .physical = .{ .value = 121 } } });
    const tab = gui.app.model.tabs.active;
    const terminal: core.PaneId = @enumFromInt(21);
    try data.pane_split.split(&gui.app.model, tab, .{ .existing_pane = Session.pane_id, .new_pane = terminal, .location = Session.location, .axis = .horizontal, .area = data.workbench.region(&gui.app.model).area });
    _ = gui.app.model.tabs.layout[tab].focusPane(terminal);
    gui.router.binding_since_ns = 0;
    gui.router.sequence_timeout_ns = 0;
    try input_support.bindingExpired(gui);
    try std.testing.expectEqual(terminal, gui.app.model.tabs.layout[tab].focused());
    try std.testing.expectEqualStrings("", gui.app.model.panes.findConst(Session.pane_id).?.composerSlice());
    try send(session, .{ .text = .{ .target_id = target.id.target_id, .generation = target.id.generation, .bytes = "g", .physical = .{ .value = 121 }, .phase = .release } });
    try expectReleasedKeys(session);
    try send(session, .{ .text = .{ .bytes = "x" } });
    try session.settle();
    try std.testing.expectEqualStrings("x", session.input[0..session.input_len]);
    try std.testing.expectEqual(terminal, session.last_input_pane.?);
}

test "agent direct navigation binding leaves the composer and releases its original native target" {
    const session = try agentSession();
    defer session.deinit();
    const gui = session.gui;
    const tab = gui.app.model.tabs.active;
    const terminal: core.PaneId = @enumFromInt(21);
    try data.pane_split.split(&gui.app.model, tab, .{ .existing_pane = Session.pane_id, .new_pane = terminal, .location = Session.location, .axis = .horizontal, .area = data.workbench.region(&gui.app.model).area });
    _ = gui.app.model.tabs.layout[tab].focusPane(Session.pane_id);
    try publish(session);
    const target = try composerTarget(session);
    adoptAgentBinding(session, try data.config_values.ConfiguredBinding.parse(&.{"ctrl+l"}, .{ .navigate_pane = .right }));
    try send(session, .{ .key = .{ .target_id = target.id.target_id, .generation = target.id.generation, .code = .{ .char = .init("l") }, .mods = .{ .ctrl = true }, .physical = .{ .value = 101 } } });
    try std.testing.expectEqual(terminal, gui.app.model.tabs.layout[tab].focused());
    try publish(session);
    try send(session, .{ .key = .{ .target_id = target.id.target_id, .generation = target.id.generation, .code = .{ .char = .init("l") }, .physical = .{ .value = 101 }, .phase = .release } });
    try session.settle();
    try expectReleasedKeys(session);
    try std.testing.expectEqualStrings("", gui.app.model.panes.findConst(Session.pane_id).?.composerSlice());
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
    try send(session, .{ .text = .{ .bytes = "x" } });
    try session.settle();
    try std.testing.expectEqual(terminal, gui.app.model.tabs.layout[tab].focused());
    try std.testing.expectEqualStrings("", gui.app.model.panes.findConst(Session.pane_id).?.composerSlice());
    try std.testing.expectEqualStrings("x", session.input[0..session.input_len]);
    try std.testing.expectEqual(terminal, session.last_input_pane.?);
}

test "agent direct history binding releases through the modal using the retired composer target" {
    const session = try agentSession();
    defer session.deinit();
    const target = try composerTarget(session);
    adoptAgentBinding(session, try data.config_values.ConfiguredBinding.parse(&.{"ctrl+r"}, .history_palette));
    try send(session, .{ .key = .{ .target_id = target.id.target_id, .generation = target.id.generation, .code = .{ .char = .init("r") }, .mods = .{ .ctrl = true }, .physical = .{ .value = 102 } } });
    try std.testing.expectEqual(.history, std.meta.activeTag(session.gui.app.model.name_prompt.currentConst().?.target()));
    try publish(session);
    try std.testing.expect(!target.id.eql(session.gui.widgets.dispatcher.focused.?));
    try send(session, .{ .key = .{ .target_id = target.id.target_id, .generation = target.id.generation, .code = .{ .char = .init("r") }, .physical = .{ .value = 102 }, .phase = .repeat } });
    try send(session, .{ .key = .{ .target_id = target.id.target_id, .generation = target.id.generation, .code = .{ .char = .init("r") }, .physical = .{ .value = 102 }, .phase = .release } });
    try expectReleasedKeys(session);
    try std.testing.expectEqualStrings("", session.gui.app.model.name_prompt.currentConst().?.field.text());
    try std.testing.expectEqualStrings("", session.gui.app.model.agentPane(Session.pane_id).?.composerSlice());
}

test "agent default prefix works from closed selectors and conversation controls" {
    for ([_]bool{ false, true }) |conversation| {
        const session = try agentSession();
        defer session.deinit();
        if (conversation) {
            try activitySnapshot(session);
        }

        const target = if (conversation) try threadItemTarget(session, 42) else try composerSelector(session, .model);
        try send(session, .{ .accessibility = .{ .target_id = target.id.target_id, .generation = target.id.generation, .action = .focus } });
        try std.testing.expect(target.id.eql(session.gui.widgets.dispatcher.focused.?));
        try std.testing.expect(session.gui.widgets.composer_menu.selector == null);
        const defaults = try client.default_bindings.load(data.keybind.default_prefix);
        const binding = defaults[0];
        try std.testing.expectEqual(.new_agent_tab, std.meta.activeTag(binding.action));
        try send(session, .{ .key = .{ .code = binding.keys[0].code, .mods = .{ .ctrl = binding.keys[0].mods.ctrl }, .physical = .{ .value = 103 } } });
        try std.testing.expect(session.gui.router.prefixPending());
        try send(session, .{ .text = .{ .bytes = binding.keys[1].code.char.bytes[0..binding.keys[1].code.char.len], .physical = .{ .value = 104 } } });
        try session.settle();
        try std.testing.expectEqual(@as(usize, 1), session.agent_tab_count);
        try send(session, .{ .key = .{ .code = binding.keys[0].code, .physical = .{ .value = 103 }, .phase = .release } });
        try send(session, .{ .text = .{ .bytes = "a", .physical = .{ .value = 104 }, .phase = .release } });
        try expectReleasedKeys(session);
        try std.testing.expectEqualStrings("", session.gui.app.model.agentPane(Session.pane_id).?.composerSlice());
    }
}

test "agent global bindings preserve prompt and open selector capture" {
    for ([_]bool{ false, true }) |menu| {
        const session = try agentSession();
        defer session.deinit();
        adoptAgentBinding(session, try data.config_values.ConfiguredBinding.parse(&.{"ctrl+r"}, .history_palette));
        if (menu) {
            try pressControl(session, try composerSelector(session, .access));
        } else {
            session.gui.app.model.name_prompt.begin(.{ .rename_tab = .{ .tab_id = Session.location.tab_id, .label = "keep" } });
        }

        try publish(session);
        try send(session, .{ .key = .{ .code = .{ .char = .init("r") }, .mods = .{ .ctrl = true }, .physical = .{ .value = 105 } } });
        try send(session, .{ .key = .{ .code = .{ .char = .init("r") }, .physical = .{ .value = 105 }, .phase = .release } });
        try send(session, .{ .key = .{ .code = .{ .char = .init("b") }, .mods = .{ .ctrl = true }, .physical = .{ .value = 106 } } });
        try std.testing.expect(!session.gui.router.prefixPending());
        try send(session, .{ .key = .{ .code = .{ .char = .init("b") }, .physical = .{ .value = 106 }, .phase = .release } });
        if (menu) {
            try std.testing.expect(session.gui.widgets.composer_menu.selector != null);
            try std.testing.expect(!session.gui.app.model.name_prompt.active());
            try std.testing.expectEqual(.workspace, session.gui.app.model.agentPane(Session.pane_id).?.agentOptions().access);
        } else {
            try std.testing.expectEqual(.rename_tab, std.meta.activeTag(session.gui.app.model.name_prompt.currentConst().?.target()));
            try std.testing.expectEqualStrings("keep", session.gui.app.model.name_prompt.currentConst().?.field.text());
        }

        try expectReleasedKeys(session);
    }
}

test "agent global shortcuts reject stale native generations and replaced attachments" {
    const session = try agentSession();
    defer session.deinit();
    const target = try composerTarget(session);
    adoptAgentBinding(session, try data.config_values.ConfiguredBinding.parse(&.{"ctrl+r"}, .history_palette));
    try send(session, .{ .key = .{ .target_id = target.id.target_id, .generation = target.id.generation + 1, .code = .{ .char = .init("r") }, .mods = .{ .ctrl = true }, .physical = .{ .value = 107 } } });
    try send(session, .{ .key = .{ .target_id = target.id.target_id, .generation = target.id.generation + 1, .code = .{ .char = .init("r") }, .physical = .{ .value = 107 }, .phase = .release } });
    try std.testing.expect(!session.gui.app.model.name_prompt.active());
    session.gui.app.model.panes.find(Session.pane_id).?.attachment_generation += 1;
    try send(session, .{ .key = .{ .target_id = target.id.target_id, .generation = target.id.generation, .code = .{ .char = .init("r") }, .mods = .{ .ctrl = true }, .physical = .{ .value = 108 } } });
    try send(session, .{ .key = .{ .target_id = target.id.target_id, .generation = target.id.generation, .code = .{ .char = .init("r") }, .physical = .{ .value = 108 }, .phase = .release } });
    try std.testing.expect(!session.gui.app.model.name_prompt.active());
    try expectReleasedKeys(session);
}

test "agent held editor keys cannot acquire a newly configured global meaning" {
    const session = try agentSession();
    defer session.deinit();
    const target = try composerTarget(session);
    try send(session, .{ .key = .{ .target_id = target.id.target_id, .generation = target.id.generation, .code = .{ .char = .init("r") }, .mods = .{ .ctrl = true }, .physical = .{ .value = 109 } } });
    adoptAgentBinding(session, try data.config_values.ConfiguredBinding.parse(&.{"ctrl+r"}, .history_palette));
    try send(session, .{ .key = .{ .target_id = target.id.target_id, .generation = target.id.generation, .code = .{ .char = .init("r") }, .mods = .{ .ctrl = true }, .physical = .{ .value = 109 }, .phase = .repeat } });
    try std.testing.expect(!session.gui.app.model.name_prompt.active());
    try send(session, .{ .key = .{ .target_id = target.id.target_id, .generation = target.id.generation, .code = .{ .char = .init("r") }, .physical = .{ .value = 109 }, .phase = .release } });
    try expectReleasedKeys(session);
    try send(session, .{ .key = .{ .target_id = target.id.target_id, .generation = target.id.generation, .code = .{ .char = .init("r") }, .mods = .{ .ctrl = true }, .physical = .{ .value = 109 } } });
    try std.testing.expectEqual(.history, std.meta.activeTag(session.gui.app.model.name_prompt.currentConst().?.target()));
    try publish(session);
    try send(session, .{ .key = .{ .target_id = target.id.target_id, .generation = target.id.generation, .code = .{ .char = .init("r") }, .physical = .{ .value = 109 }, .phase = .release } });
    try expectReleasedKeys(session);
}

test "agent unprefixed sequences consume matches and replay mismatches to the composer" {
    for ([_]bool{ false, true }) |matched| {
        const session = try agentSession();
        defer session.deinit();
        const target = try composerTarget(session);
        adoptAgentBinding(session, try data.config_values.ConfiguredBinding.parse(&.{ "g", "g" }, .toggle_sidebar));
        const visible = session.gui.app.model.sidebar_visible;
        try send(session, .{ .text = .{ .target_id = target.id.target_id, .generation = target.id.generation, .bytes = "g", .physical = .{ .value = 110 } } });
        try std.testing.expectEqualStrings("", session.gui.app.model.agentPane(Session.pane_id).?.composerSlice());
        const suffix = if (matched) "g" else "x";
        try send(session, .{ .text = .{ .target_id = target.id.target_id, .generation = target.id.generation, .bytes = suffix, .physical = .{ .value = 111 } } });
        try std.testing.expectEqual(if (matched) !visible else visible, session.gui.app.model.sidebar_visible);
        try std.testing.expectEqualStrings(if (matched) "" else "gx", session.gui.app.model.agentPane(Session.pane_id).?.composerSlice());
        try send(session, .{ .text = .{ .target_id = target.id.target_id, .generation = target.id.generation, .bytes = "g", .physical = .{ .value = 110 }, .phase = .release } });
        try send(session, .{ .text = .{ .target_id = target.id.target_id, .generation = target.id.generation, .bytes = suffix, .physical = .{ .value = 111 }, .phase = .release } });
        try expectReleasedKeys(session);
        try session.settle();
        try std.testing.expectEqual(@as(usize, 0), session.input_len);
    }
}

test "agent unprefixed sequence timeout restores text and physical ownership to the composer" {
    const session = try agentSession();
    defer session.deinit();
    const target = try composerTarget(session);
    adoptAgentBinding(session, try data.config_values.ConfiguredBinding.parse(&.{ "g", "g" }, .toggle_sidebar));
    const visible = session.gui.app.model.sidebar_visible;
    try send(session, .{ .text = .{ .target_id = target.id.target_id, .generation = target.id.generation, .bytes = "g", .physical = .{ .value = 112 } } });
    session.gui.router.binding_since_ns = 0;
    session.gui.router.sequence_timeout_ns = 0;
    try input_support.bindingExpired(session.gui);
    try std.testing.expectEqualStrings("g", session.gui.app.model.agentPane(Session.pane_id).?.composerSlice());
    try std.testing.expectEqual(visible, session.gui.app.model.sidebar_visible);
    try std.testing.expectEqual(@as(usize, 0), session.gui.router.leases.len);
    const owner = session.gui.widgets.dispatcher.keys.owner(.{ .value = 112 }).?;
    try std.testing.expect(owner == .widget and owner.widget.eql(target.id));
    try send(session, .{ .text = .{ .target_id = target.id.target_id, .generation = target.id.generation, .bytes = "g", .physical = .{ .value = 112 }, .phase = .repeat } });
    try std.testing.expectEqualStrings("gg", session.gui.app.model.agentPane(Session.pane_id).?.composerSlice());
    try std.testing.expectEqual(visible, session.gui.app.model.sidebar_visible);
    try send(session, .{ .text = .{ .target_id = target.id.target_id, .generation = target.id.generation, .bytes = "g", .physical = .{ .value = 112 }, .phase = .release } });
    try expectReleasedKeys(session);
}

test "agent IME commits never start or complete a global character binding" {
    const session = try agentSession();
    defer session.deinit();
    const target = try composerTarget(session);
    adoptAgentBinding(session, try data.config_values.ConfiguredBinding.parse(&.{ "g", "g" }, .toggle_sidebar));
    const visible = session.gui.app.model.sidebar_visible;
    try send(session, .{ .composition = .{ .target_id = target.id.target_id, .generation = target.id.generation, .text = "g", .selection_start = 1, .selection_end = 1 } });
    try send(session, .{ .text = .{ .target_id = target.id.target_id, .generation = target.id.generation, .bytes = "g" } });
    try std.testing.expectEqualStrings("g", session.gui.app.model.agentPane(Session.pane_id).?.composerSlice());
    try std.testing.expect(session.gui.router.bindingDeadline() == null);
    try send(session, .{ .text = .{ .target_id = target.id.target_id, .generation = target.id.generation, .bytes = "g", .physical = .{ .value = 113 } } });
    try send(session, .{ .composition = .{ .target_id = target.id.target_id, .generation = target.id.generation, .text = "g", .selection_start = 1, .selection_end = 1 } });
    try send(session, .{ .text = .{ .target_id = target.id.target_id, .generation = target.id.generation, .bytes = "g" } });
    try std.testing.expectEqual(visible, session.gui.app.model.sidebar_visible);
    try std.testing.expectEqualStrings("gg", session.gui.app.model.agentPane(Session.pane_id).?.composerSlice());
    try send(session, .{ .text = .{ .target_id = target.id.target_id, .generation = target.id.generation, .bytes = "g", .physical = .{ .value = 113 }, .phase = .release } });
    try expectReleasedKeys(session);
}

test "one native input batch retires composer replay ownership before a terminal sequence begins" {
    const session = try agentSession();
    defer session.deinit();
    const gui = session.gui;
    adoptAgentBinding(session, try data.config_values.ConfiguredBinding.parse(&.{ "g", "g" }, .toggle_sidebar));
    const tab = gui.app.model.tabs.active;
    const terminal: core.PaneId = @enumFromInt(21);
    try data.pane_split.split(&gui.app.model, tab, .{ .existing_pane = Session.pane_id, .new_pane = terminal, .location = Session.location, .axis = .horizontal, .area = data.workbench.region(&gui.app.model).area });
    _ = gui.app.model.tabs.layout[tab].focusPane(Session.pane_id);
    try publish(session);
    const target = try composerTarget(session);
    const view = data.tab_layout.view(&gui.app.model, tab, terminal, data.workbench.region(&gui.app.model).area).?;
    const size = gui.app.model.host.host_size;
    const x = @as(f64, @floatFromInt(view.content.x)) * size.cell_width_px + @as(f64, @floatFromInt(session.gui.renderer.origin[0])) + 1;
    const y = @as(f64, @floatFromInt(view.content.y)) * size.cell_height_px + @as(f64, @floatFromInt(session.gui.renderer.origin[1])) + 1;
    try input_support.accept(gui, .{ .text = .{ .target_id = target.id.target_id, .generation = target.id.generation, .bytes = "g", .physical = .{ .value = 114 } } });
    try input_support.accept(gui, .{ .text = .{ .target_id = target.id.target_id, .generation = target.id.generation, .bytes = "g", .physical = .{ .value = 114 }, .phase = .release } });
    try input_support.accept(gui, .{ .pointer = .{ .kind = .press, .x = x, .y = y } });
    try input_support.accept(gui, .{ .pointer = .{ .kind = .release, .x = x, .y = y } });
    try input_support.accept(gui, .{ .text = .{ .bytes = "g", .physical = .{ .value = 115 } } });
    try input_support.pump(gui);
    try std.testing.expectEqual(terminal, gui.app.model.tabs.layout[tab].focused());
    try std.testing.expect(gui.router.bindingDeadline() != null);
    try std.testing.expectEqualStrings("", gui.app.model.panes.findConst(Session.pane_id).?.composerSlice());
    gui.router.binding_since_ns = 0;
    gui.router.sequence_timeout_ns = 0;
    try input_support.bindingExpired(gui);
    try session.settle();
    try std.testing.expectEqualStrings("g", session.input[0..session.input_len]);
    try std.testing.expectEqualStrings("", gui.app.model.panes.findConst(Session.pane_id).?.composerSlice());
    try send(session, .{ .text = .{ .bytes = "g", .physical = .{ .value = 115 }, .phase = .release } });
    try expectReleasedKeys(session);
}

test "message link hover owns normalized URL without changing source or editor focus" {
    const session = try agentSession();
    defer session.deinit();
    const source = "Read [`input`](/project/my\\(file\\).zig:346?x=1&amp;y=2).";
    try linkSnapshot(session, source);
    try publish(session);
    const composer = try composerTarget(session);
    try pressControl(session, composer);
    const target = try messageLinkTarget(session);
    try std.testing.expectEqualStrings("input", target.label[0..target.label_len]);
    try std.testing.expect(session.gui.widgets.message_link_preview == null);
    try hoverMessageLink(session, target);
    const state = &session.gui.widgets;
    try std.testing.expectEqualStrings("/project/my(file).zig:346?x=1&y=2", state.message_link_preview.?.destination.text());
    try std.testing.expect(composer.id.eql(state.dispatcher.focused.?));
    const snapshot = session.gui.app.model.agentPane(Session.pane_id).?.agent_thread.?;
    try std.testing.expectEqualStrings(source, snapshot.items()[0].text(snapshot));
    try publish(session);
    const revision = state.dispatcher.revision;
    try hoverMessageLink(session, target);
    try std.testing.expectEqual(revision, state.dispatcher.revision);
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
    try send(session, .{ .pointer = .{ .kind = .leave, .x = target.bounds.x, .y = target.bounds.y } });
    try session.settle();
    try std.testing.expect(state.message_link_preview == null);
    try std.testing.expectEqual(.default, session.gui.pointer.hover.shape);
    try hoverMessageLink(session, target);
    try std.testing.expectEqual(.pointer, session.gui.pointer.hover.shape);
    try input_support.focus(session.gui, false);
    try std.testing.expect(state.message_link_preview == null);
}

test "message link hover rejects stale snapshots and failed delivery before accepting the replacement" {
    const session = try agentSession();
    defer session.deinit();
    const links = @import("../widgets/interaction/message_links.zig");
    try linkSnapshot(session, "[documentation](https://example.test/old)");
    try publish(session);
    const old = try messageLinkTarget(session);
    try hoverMessageLink(session, old);
    try std.testing.expectEqualStrings("https://example.test/old", session.gui.widgets.message_link_preview.?.destination.text());
    try linkSnapshot(session, "[documentation](https://example.test/new)");
    try session.settle();
    try std.testing.expect(session.gui.widgets.message_link_preview == null);
    try std.testing.expect(links.destination(session.gui, old.action.message_link) == null);
    const failed = try session.draw();
    try input_support.presented(
        session.gui,
        failed,
        false,
    );
    try hoverMessageLink(session, old);
    try std.testing.expect(session.gui.widgets.message_link_preview == null);
    try publish(session);
    const replacement = try messageLinkTarget(session);
    try hoverMessageLink(session, replacement);
    try std.testing.expectEqualStrings("https://example.test/new", session.gui.widgets.message_link_preview.?.destination.text());
    var invalid = replacement.action.message_link;
    invalid.destination_offset = std.math.maxInt(u32);
    try std.testing.expect(links.destination(session.gui, invalid) == null);
    invalid = replacement.action.message_link;
    invalid.destination_len = std.math.maxInt(u32);
    try std.testing.expect(links.destination(session.gui, invalid) == null);
    invalid = replacement.action.message_link;
    invalid.owner.item_identity += 1;
    try std.testing.expect(links.destination(session.gui, invalid) == null);
    session.gui.app.model.panes.find(Session.pane_id).?.attachment_generation += 1;
    try session.settle();
    try std.testing.expect(session.gui.widgets.message_link_preview == null);
}

test "message link hover yields to composer menus and modal prompts" {
    const session = try agentSession();
    defer session.deinit();
    try linkSnapshot(session, "[documentation](https://example.test)");
    try publish(session);
    const link = try messageLinkTarget(session);
    try hoverMessageLink(session, link);
    const selector = try composerSelector(session, .model);
    try pressControl(session, selector);
    try hoverMessageLink(session, link);
    try std.testing.expect(session.gui.widgets.message_link_preview == null);
    try send(session, .{ .key = .{ .code = .escape } });
    try publish(session);
    try hoverMessageLink(session, try messageLinkTarget(session));
    try std.testing.expect(session.gui.widgets.message_link_preview != null);
    session.gui.app.model.name_prompt.begin(.{ .rename_tab = .{ .tab_id = Session.location.tab_id, .label = "hello" } });
    try session.settle();
    try std.testing.expect(session.gui.widgets.message_link_preview == null);
}

test "wheel input on message links scrolls the owning conversation" {
    const session = try agentSession();
    defer session.deinit();
    try linkSnapshot(session, "Earlier output\n" ** 40 ++ "[documentation](https://example.test)");
    try publish(session);
    const link = try messageLinkTarget(session);
    try hoverMessageLink(session, link);
    const pane = session.gui.app.model.agentPane(Session.pane_id).?;
    const before = pane.transcript_scroll;
    try send(session, .{ .pointer = .{ .kind = .scroll_up, .x = link.bounds.x + 2, .y = link.bounds.y + 2 } });
    try settleConversationScroll(session);
    try std.testing.expect(pane.transcript_scroll > before);
    try publish(session);
    try std.testing.expect(session.gui.widgets.message_link_preview == null);
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
}

test "precise conversation scrolling moves on every fractional delta including momentum and reversal" {
    const session = try agentSession();
    defer session.deinit();
    try linkSnapshot(session, "Earlier output\n" ** 40 ++ "[documentation](https://example.test)");
    try publish(session);
    const link = try messageLinkTarget(session);
    const pane = session.gui.app.model.agentPane(Session.pane_id).?;
    const step = session.gui.renderer.chrome.px(24);
    var displacement: f64 = 0;
    const Phase = @FieldType(ScrollEvent, "phase");
    for ([_]Phase{ .begin, .update, .end, .none, .none, .none, .begin, .update }, 0..) |phase, index| {
        const delta: f64 = if (index < 6) -0.25 else 0.125;
        try send(session, .{ .scroll = .{ .x = link.bounds.x + 2, .y = link.bounds.y + 2, .delta_y = delta, .precise = true, .phase = phase, .momentum = if (index >= 3 and index < 6) .update else .none } });
        displacement -= delta;
        try std.testing.expectApproxEqAbs(displacement / step, pane.transcript_scroll, 0.000001);
        try publish(session);
        const moved = try messageLinkTarget(session);
        try std.testing.expectApproxEqAbs(@as(f64, link.bounds.y) + displacement, moved.bounds.y, 0.001);
    }

    try send(session, .{ .scroll = .{ .x = link.bounds.x + 2, .y = link.bounds.y + 2, .delta_y = 20, .precise = true, .phase = .cancel } });
    try std.testing.expectApproxEqAbs(displacement / step, pane.transcript_scroll, 0.000001);
    const failed = try session.draw();
    try input_support.presented(
        session.gui,
        failed,
        false,
    );
    try publish(session);
    try std.testing.expectApproxEqAbs(@as(f64, link.bounds.y) + displacement, (try messageLinkTarget(session)).bounds.y, 0.001);
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
}

test "resolved approval review no longer captures conversation history scrolling" {
    const session = try agentSession();
    defer session.deinit();
    var approval: core.AgentApprovalRequest = .{ .id = 91, .kind = .command, .description_len = 5 };
    @memcpy(approval.description[0..5], "build");
    try agentSnapshot(session, .blocked, approval);
    try publish(session);
    const registry = session.gui.widgets.dispatcher.maps.presented();
    const review = for (registry.targets[0..registry.len]) |target| {
        if (target.action == .agent_control and target.action.agent_control.kind == .review) {
            break target;
        }
    } else return error.MissingReview;
    try pressControl(session, review);
    try std.testing.expect(session.gui.widgets.approval_review != null);
    try agentSnapshot(session, .ready, null);
    const pane = session.gui.app.model.agentPane(Session.pane_id).?;
    var snapshot = pane.agent_thread.?.*;
    snapshot.revision += 1;
    snapshot.truncated = true;
    try receiveThread(session, &snapshot);
    try publish(session);
    const delivered = session.gui.widgets.dispatcher.maps.presented();
    const transcript = for (delivered.targets[0..delivered.len]) |target| {
        if (target.action == .transcript) {
            break target;
        }
    } else return error.MissingTranscript;
    try send(session, .{ .pointer = .{ .kind = .scroll_up, .x = transcript.bounds.x + 1, .y = transcript.bounds.y + 1 } });
    try std.testing.expectEqual(core.agent_history.Direction.older, pane.agent_history.?.pending.?);
    try std.testing.expect(session.gui.app.model.request_lifecycle.tracker.has(.agent_history));
}

test "delayed composer cut cannot steal focus from another agent split" {
    const session = try agentSession();
    defer session.deinit();
    const gui = session.gui;
    const tab = gui.app.model.tabs.active;
    const second: core.PaneId = @enumFromInt(20);
    try data.pane_split.split(&gui.app.model, tab, .{ .existing_pane = Session.pane_id, .new_pane = second, .location = Session.location, .axis = .horizontal, .area = data.workbench.region(&gui.app.model).area });
    try std.testing.expect(gui.app.model.identifyPane(.{ .request_id = @enumFromInt(2), .pane_id = second, .location = Session.location, .created = false, .kind = .agent, .pane_generation = 78 }));
    var snapshot = gui.app.model.panes.findConst(Session.pane_id).?.agent_thread.?.*;
    snapshot.pane_id = second;
    snapshot.pane_generation = 78;
    try receiveThread(session, &snapshot);
    try publish(session);
    const first = try composerTarget(session);
    try send(session, .{ .accessibility = .{ .action = .focus, .target_id = first.id.target_id, .generation = first.id.generation } });
    try send(session, .{ .text = .{ .bytes = "keep" } });
    _ = gui.app.model.editAgentComposer(Session.pane_id, .select_all);
    try send(session, .{ .key = .{ .code = .{ .char = .init("x") }, .mods = .{ .super = true } } });
    var request: native.HostRequest = .{};
    try std.testing.expect(gui.host.next(&request));
    try std.testing.expectEqualStrings("keep", request.text.?[0..request.len]);
    const registry = gui.widgets.dispatcher.maps.presented();
    const other = for (registry.targets[0..registry.len]) |target| {
        if (target.action == .composer and target.action.composer == second) {
            break target;
        }
    } else return error.MissingSecondComposer;
    try send(session, .{ .accessibility = .{ .action = .focus, .target_id = other.id.target_id, .generation = other.id.generation } });
    try send(session, .{ .clipboard = .{ .request_id = request.request_id, .target_id = request.target_id, .generation = request.generation, .status = .success } });
    try std.testing.expectEqualStrings("keep", gui.app.model.panes.findConst(Session.pane_id).?.composerSlice());
    try std.testing.expect(other.id.eql(gui.widgets.dispatcher.focused.?));
    try std.testing.expectEqual(second, gui.app.model.tabs.layout[tab].focused());
    try send(session, .{ .text = .{ .bytes = "second" } });
    try std.testing.expectEqualStrings("second", gui.app.model.panes.findConst(second).?.composerSlice());
}

test "delayed composer paste rejects changed draft and caret but preserves an unchanged selection" {
    const session = try agentSession();
    defer session.deinit();
    const gui = session.gui;
    const target = try composerTarget(session);
    const pane = gui.app.model.agentPane(Session.pane_id).?;
    try send(session, .{ .text = .{ .bytes = "keep" } });
    _ = gui.app.model.editAgentComposer(pane.id, .select_all);
    try send(session, .{ .key = .{ .code = .{ .char = .init("v") }, .mods = .{ .super = true } } });
    var request: native.HostRequest = .{};
    try std.testing.expect(gui.host.next(&request));
    try send(session, .{ .text = .{ .bytes = "changed" } });
    try send(session, .{ .clipboard = .{ .request_id = request.request_id, .target_id = request.target_id, .generation = request.generation, .status = .success, .text = "stale" } });
    try std.testing.expectEqualStrings("changed", pane.composerSlice());
    try gui.requestClipboardRead(target.id.target_id, target.id.generation);
    try std.testing.expect(gui.host.next(&request));
    try send(session, .{ .key = .{ .code = .left } });
    try send(session, .{ .clipboard = .{ .request_id = request.request_id, .target_id = request.target_id, .generation = request.generation, .status = .success, .text = "stale" } });
    try std.testing.expectEqualStrings("changed", pane.composerSlice());
    _ = gui.app.model.editAgentComposer(pane.id, .select_all);
    try gui.requestClipboardRead(target.id.target_id, target.id.generation);
    try std.testing.expect(gui.host.next(&request));
    try send(session, .{ .clipboard = .{ .request_id = request.request_id, .target_id = request.target_id, .generation = request.generation, .status = .success, .text = "one\r\ntwo" } });
    try std.testing.expectEqualStrings("one\ntwo", pane.composerSlice());
    for (gui.widgets.pending_pastes) |pending| {
        try std.testing.expect(pending == null);
    }
}

test "recent conversation menu resumes by keyboard without submitting or losing the draft" {
    const session = try agentSession();
    defer session.deinit();
    var snapshot = session.gui.app.model.agentPane(Session.pane_id).?.agent_thread.?.*;
    snapshot.revision += 1;
    snapshot.item_count = 0;
    snapshot.text_len = 0;
    snapshot.recent = .{ .phase = .ready };
    try snapshot.recent.append(try core.RecentConversation.init("older", "Parser fixes"));
    try snapshot.recent.append(try core.RecentConversation.init("newer", "Input routing"));
    try receiveThread(session, &snapshot);
    _ = session.gui.app.model.editAgentComposer(
        Session.pane_id,
        .{
            .insert = "Continue from yesterday",
        },
    );
    try publish(session);
    try pressControl(session, try composerSelector(session, .recent));
    try publish(session);
    try std.testing.expectEqual(.recent, session.gui.widgets.composer_menu.selector.?.kind);
    try send(session, .{ .key = .{ .code = .down } });
    try publish(session);
    try send(session, .{ .key = .{ .code = .enter } });
    try session.settle();
    try std.testing.expectEqual(1, session.agent_resume_count);
    try std.testing.expectEqual(1, session.last_resume.?.conversation_index);
    try std.testing.expectEqual(snapshot.revision, session.last_resume.?.expected_revision);
    try std.testing.expectEqual(77, session.last_resume.?.pane_generation);
    try std.testing.expectEqualStrings("Continue from yesterday", session.gui.app.model.agentPane(Session.pane_id).?.composerSlice());
    try std.testing.expectEqual(0, session.agent_prompt_count);
    try std.testing.expectEqual(0, session.input_len);
    try std.testing.expect(session.gui.widgets.composer_menu.selector == null);
}

test "a recent menu cannot replace a conversation after another client starts a turn" {
    const session = try agentSession();
    defer session.deinit();
    var snapshot = session.gui.app.model.agentPane(Session.pane_id).?.agent_thread.?.*;
    snapshot.revision += 1;
    snapshot.item_count = 0;
    snapshot.text_len = 0;
    snapshot.recent = .{ .phase = .ready };
    try snapshot.recent.append(try core.RecentConversation.init("previous", "Parser fixes"));
    try receiveThread(session, &snapshot);
    try publish(session);
    try pressControl(session, try composerSelector(session, .recent));
    try publish(session);
    snapshot.revision += 1;
    snapshot.status = .working;
    try receiveThread(session, &snapshot);
    try send(session, .{ .key = .{ .code = .enter } });
    try session.settle();
    try std.testing.expectEqual(0, session.agent_resume_count);
    try std.testing.expect(session.gui.widgets.composer_menu.selector == null);
}

test "Command V attaches images and image-only send owns them through acknowledgement" {
    const session = try agentSession();
    defer session.deinit();
    const gui = session.gui;
    const target = try composerTarget(session);
    try send(session, .{ .key = .{ .code = .{ .char = .init("v") }, .mods = .{ .super = true } } });
    var request: native.HostRequest = .{};
    try std.testing.expect(gui.host.next(&request));
    try std.testing.expectEqual(@as(u32, 3), request.kind);
    try std.testing.expectEqual(target.id.target_id, request.target_id);
    try send(session, .{ .key = .{ .code = .enter } });
    try session.settle();
    try std.testing.expectEqual(@as(usize, 0), session.agent_prompt_count);
    try send(session, .{ .clipboard = .{ .request_id = request.request_id, .target_id = request.target_id, .generation = request.generation, .status = .success, .image = true, .text = "/tmp/clipboard.png" } });
    const pane = gui.app.model.agentPane(Session.pane_id).?;
    try std.testing.expectEqualStrings("", pane.composerSlice());
    try std.testing.expectEqualStrings("/tmp/clipboard.png", pane.composerImages().path(0));
    try publish(session);
    try std.testing.expect((try promptControl(session, "Send message")).enabled);
    try std.testing.expect((try promptControl(session, "Remove image 1")).enabled);
    try send(session, .{ .key = .{ .code = .enter } });
    try session.settle();
    try std.testing.expectEqual(@as(usize, 1), session.agent_prompt_count);
    try std.testing.expectEqualStrings("/tmp/clipboard.png", session.agent_images.path(0));
    try std.testing.expectEqual(@as(u8, 1), pane.composerImages().count);
    _ = try client.runtime_messages.handleServerMessage(
        &gui.app,
        .{
            .request_completed = .{
                .request_id = session.agent_request_id,
            },
        },
    );
    try std.testing.expectEqual(@as(u8, 0), pane.composerImages().count);
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
}

test "image paste keeps text fallback and rejects edited or replaced drafts" {
    const session = try agentSession();
    defer session.deinit();
    const gui = session.gui;
    var target = try composerTarget(session);
    try gui.requestClipboardRead(target.id.target_id, target.id.generation);
    var request: native.HostRequest = .{};
    try std.testing.expect(gui.host.next(&request));
    try send(session, .{ .clipboard = .{ .request_id = request.request_id, .target_id = request.target_id, .generation = request.generation, .status = .success, .text = "ordinary text" } });
    try std.testing.expectEqualStrings("ordinary text", gui.app.model.agentPane(Session.pane_id).?.composerSlice());
    try publish(session);
    target = try composerTarget(session);
    for (0..2) |attempt| {
        try gui.requestClipboardRead(target.id.target_id, target.id.generation);
        try std.testing.expect(gui.host.next(&request));
        if (attempt == 0) {
            try send(session, .{ .text = .{ .bytes = " edited" } });
        } else {
            gui.app.model.panes.find(Session.pane_id).?.attachment_generation += 1;
        }

        try send(session, .{ .clipboard = .{ .request_id = request.request_id, .target_id = request.target_id, .generation = request.generation, .status = .success, .image = true, .text = "/tmp/stale.png" } });
        try std.testing.expectEqual(@as(u8, 0), gui.app.model.agentPane(Session.pane_id).?.composerImages().count);
    }
}

test "image removal revalidates the delivered draft and preserves remaining order" {
    const session = try agentSession();
    defer session.deinit();
    const gui = session.gui;
    try client.agent_control.attachAgentImage(&gui.app, Session.pane_id, "/tmp/first.png");
    try client.agent_control.attachAgentImage(&gui.app, Session.pane_id, "/tmp/second.png");
    try publish(session);
    const first = try promptControl(session, "Remove image 1");
    _ = gui.app.model.editAgentComposer(
        Session.pane_id,
        .{
            .insert = "later",
        },
    );
    try pressControl(session, first);
    try std.testing.expectEqual(@as(u8, 2), gui.app.model.agentPane(Session.pane_id).?.composerImages().count);
    try publish(session);
    try pressControl(session, try promptControl(session, "Remove image 1"));
    const images = gui.app.model.agentPane(Session.pane_id).?.composerImages();
    try std.testing.expectEqual(@as(u8, 1), images.count);
    try std.testing.expectEqualStrings("/tmp/second.png", images.path(0));
}

test "image preview opens separately from removal and blocks draft input until Escape" {
    const session = try agentSession();
    defer session.deinit();
    const gui = session.gui;
    try client.agent_control.attachAgentImage(&gui.app, Session.pane_id, "/tmp/preview.png");
    try publish(session);
    try pressControl(session, try promptControl(session, "Preview image 1"));
    try std.testing.expect(gui.widgets.image_preview != null);
    try std.testing.expectEqualStrings("/tmp/preview.png", gui.widgets.image_preview.?.path());
    try send(session, .{ .text = .{ .bytes = "must not edit" } });
    try publish(session);
    try std.testing.expectEqual(@as(u8, 1), gui.widgets.dispatcher.maps.presented().modal_layer);
    try send(session, .{ .text = .{ .bytes = "also blocked" } });
    try send(session, .{ .key = .{ .code = .enter } });
    try std.testing.expect(gui.widgets.image_preview == null);
    try publish(session);
    try pressControl(session, try promptControl(session, "Preview image 1"));
    try publish(session);
    try send(session, .{ .key = .{ .code = .escape } });
    try std.testing.expect(gui.widgets.image_preview == null);
    try publish(session);
    try std.testing.expectEqual(@as(u8, 0), gui.widgets.dispatcher.maps.presented().modal_layer);
    try std.testing.expectEqualStrings("", gui.app.model.agentPane(Session.pane_id).?.composerSlice());
    try std.testing.expectEqual(@as(u8, 1), gui.app.model.agentPane(Session.pane_id).?.composerImages().count);
    try std.testing.expectEqual(@as(usize, 0), session.agent_prompt_count);
}

test "image preview closes with its button and backdrop and rejects obsolete image controls" {
    const session = try agentSession();
    defer session.deinit();
    const gui = session.gui;
    try client.agent_control.attachAgentImage(&gui.app, Session.pane_id, "/tmp/preview.png");
    try publish(session);
    const stale = try promptControl(session, "Preview image 1");
    _ = gui.app.model.editAgentComposer(
        Session.pane_id,
        .{
            .insert = "later",
        },
    );
    try pressControl(session, stale);
    try std.testing.expect(gui.widgets.image_preview == null);
    for (0..2) |attempt| {
        try publish(session);
        try pressControl(session, try promptControl(session, "Preview image 1"));
        try publish(session);
        const registry = gui.widgets.dispatcher.maps.presented();
        for (registry.targets[0..registry.len]) |target| {
            if (target.action == .agent_control and target.action.agent_control.kind == .close_image and target.focusable) {
                if (attempt == 0) {
                    try pressControl(session, target);
                } else {
                    try send(session, .{ .pointer = .{ .kind = .press, .x = 1, .y = 1 } });
                    try send(session, .{ .pointer = .{ .kind = .release, .x = 1, .y = 1 } });
                }
                break;
            }
        }
        try std.testing.expect(gui.widgets.image_preview == null);
    }
    try publish(session);
    try pressControl(session, try promptControl(session, "Preview image 1"));
    gui.app.model.panes.find(Session.pane_id).?.attachment_generation += 1;
    try publish(session);
    try std.testing.expect(gui.widgets.image_preview == null);
}

test "programmatic disclosure is idempotent and rejects missing visible items" {
    const session = try agentSession();
    defer session.deinit();
    try activitySnapshot(session);
    const target = try threadItemTarget(session, 42);
    const request: client.ThreadExpansion = .{ .pane_id = Session.pane_id, .item_id = 42, .expanded = true };
    try thread_items.setExpansion(session.gui, request);
    try std.testing.expect(session.gui.widgets.threadExpanded(target.action.thread_item));
    const revision = session.gui.widgets.dispatcher.revision;
    try thread_items.setExpansion(session.gui, request);
    try std.testing.expectEqual(revision, session.gui.widgets.dispatcher.revision);
    try thread_items.setExpansion(session.gui, .{ .pane_id = Session.pane_id, .item_id = 42, .expanded = false });
    try std.testing.expect(!session.gui.widgets.threadExpanded(target.action.thread_item));
    try std.testing.expectError(error.ThreadItemNotVisible, thread_items.setExpansion(session.gui, .{ .pane_id = Session.pane_id, .item_id = 999, .expanded = true }));
}

test "clicking an agent file link creates an editor pane in its source tab" {
    const session = try agentSession();
    defer session.deinit();
    var diagnostic: data.Diagnostic = .{};
    session.gui.app.lua_generation = try client.Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = "return { api_version = 2, client = { editor = '/usr/bin/nvim' } }", .source_name = "@config.lua", .number = 1 });
    try std.testing.expectEqualStrings("", session.gui.app.options.editor);
    try linkSnapshot(session, "Read [design](</tmp/a b '$(touch nope).md>).");
    try publish(session);
    const link = try messageLinkTarget(session);
    try pressControl(session, link);
    try session.settle();

    try std.testing.expectEqual(@as(usize, 1), session.pane_creation_count);
    try std.testing.expectEqual(@as(usize, 0), session.tab_creation_count);
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
    const request = (try core.decodeClient(session.pane_creation_wire[0..session.pane_creation_len])).create_pane;
    try std.testing.expectEqualDeep(Session.location, request.location);
    try std.testing.expectEqual(Session.pane_id, request.launch.cwd_source.?);
    var arguments = request.launch.arguments();
    try std.testing.expectEqualStrings("/usr/bin/nvim", (try arguments.next()).?);
    try std.testing.expectEqualStrings("/tmp/a b '$(touch nope).md", (try arguments.next()).?);
    try std.testing.expect((try arguments.next()) == null);

    var response: [128]u8 = undefined;
    const editor_id: core.PaneId = @enumFromInt(99);
    const opened = try core.encodePaneOpened(&response, .{ .request_id = request.request_id, .pane_id = editor_id, .location = request.location, .created = true });
    _ = try client.runtime_messages.handleServerMessage(&session.gui.app, try core.decodeServer(opened));
    try session.settle();
    const tab = session.gui.app.model.tabs.active;
    try std.testing.expectEqualDeep(Session.location, session.gui.app.model.tabs.location[tab]);
    try std.testing.expectEqual(@as(usize, 2), session.gui.app.model.panes.countIn(session.gui.app.model.tabs.location[tab].tab_id));
    try std.testing.expectEqual(editor_id, session.gui.app.model.tabs.layout[tab].focused());
    try std.testing.expectEqual(core.PaneKind.terminal, session.gui.app.model.panes.findConst(editor_id).?.kind);
    try std.testing.expectEqual(core.PaneKind.agent, session.gui.app.model.panes.findConst(Session.pane_id).?.kind);
}

test "agent file link clicks reject replaced snapshots and missing editors" {
    const session = try agentSession();
    defer session.deinit();
    try linkSnapshot(session, "[design](/tmp/old.md)");
    try publish(session);
    const old = try messageLinkTarget(session);
    try linkSnapshot(session, "[design](/tmp/new.md)");
    try pressControl(session, old);
    try session.settle();
    try std.testing.expectEqual(@as(usize, 0), session.pane_creation_count);

    try publish(session);
    try pressControl(session, try messageLinkTarget(session));
    try session.settle();
    try std.testing.expectEqual(@as(usize, 0), session.pane_creation_count);
}

test "dragging an agent file link retains text selection without launching an editor" {
    const session = try agentSession();
    defer session.deinit();
    session.gui.app.options.editor = "nvim";
    try linkSnapshot(session, "[select this design document](/tmp/design.md)");
    try publish(session);
    const link = try messageLinkTarget(session);
    const x = link.bounds.x + 1;
    const y = link.bounds.y + link.bounds.height / 2;
    try send(session, .{ .pointer = .{ .kind = .press, .x = x, .y = y } });
    try send(session, .{ .pointer = .{ .kind = .drag, .x = x + link.bounds.width / 2, .y = y } });
    try send(session, .{ .pointer = .{ .kind = .release, .x = x + link.bounds.width / 2, .y = y } });
    try session.settle();
    try std.testing.expectEqual(@as(usize, 0), session.pane_creation_count);
    try std.testing.expect(session.gui.widgets.thread_selection.selected());
}

fn reviewControlCount(session: *Session) usize {
    const registry = session.gui.widgets.dispatcher.maps.presented();
    var count: usize = 0;
    for (registry.targets[0..registry.len]) |target| {
        if (target.action == .change_review) {
            count += 1;
        }
    }

    return count;
}

fn reviewControl(session: *Session) !Target {
    const registry = session.gui.widgets.dispatcher.maps.presented();
    for (registry.targets[0..registry.len]) |target| {
        if (target.action == .change_review) {
            return target;
        }
    }

    return error.MissingChangeReviewButton;
}

test "review changes stays hidden in terminal and managed panes without editions" {
    const terminal = try initSession();
    defer terminal.deinit();
    _ = terminal.gui.app.model.panes.find(Session.pane_id).?.identify(.terminal, 77);
    try publish(terminal);
    try std.testing.expectEqual(@as(usize, 0), reviewControlCount(terminal));

    const agent = try agentSession();
    defer agent.deinit();
    try std.testing.expectEqual(@as(usize, 0), reviewControlCount(agent));
}

test "hook editions show one terminal review action and retired availability rejects delivered controls" {
    const session = try initSession();
    defer session.deinit();
    const gui = session.gui;
    const pane = gui.app.model.panes.find(Session.pane_id).?;
    _ = pane.identify(.terminal, 77);
    const notice: core.ChangeReviewChanged = .{ .pane_id = Session.pane_id, .pane_generation = 77, .session = "hook-thread", .latest_edition_id = 1 };
    _ = try client.runtime_messages.handleServerMessage(
        &gui.app,
        .{
            .change_review_changed = notice,
        },
    );
    try publish(session);
    const registry = gui.widgets.dispatcher.maps.presented();
    try std.testing.expectEqual(@as(usize, 1), reviewControlCount(session));
    const target = try reviewControl(session);
    try std.testing.expectEqualStrings("Review changes", target.label[0..target.label_len]);
    try std.testing.expect(target.activatable());
    try std.testing.expect(routing.eligible(gui, target));
    try std.testing.expectEqual(target.id, registry.at(.{ target.bounds.x + target.bounds.width / 2, target.bounds.y + target.bounds.height / 2 }).?.id);
    _ = try client.runtime_messages.handleServerMessage(
        &gui.app,
        .{
            .change_review_changed = .{
                .pane_id = Session.pane_id,
                .pane_generation = 77,
                .session = "new-hook-thread",
                .latest_edition_id = 0,
            },
        },
    );
    try std.testing.expect(!routing.eligible(gui, target));
    try publish(session);
    try std.testing.expectEqual(@as(usize, 0), reviewControlCount(session));

    _ = try client.runtime_messages.handleServerMessage(
        &gui.app,
        .{
            .change_review_changed = notice,
        },
    );
    try publish(session);
    try std.testing.expectEqual(@as(usize, 1), reviewControlCount(session));
    pane.attachment_generation += 1;
    try std.testing.expect(!routing.eligible(gui, target));
}

test "managed review has exactly one action across single split and fullscreen layouts" {
    const session = try agentSession();
    defer session.deinit();
    const gui = session.gui;
    const tab = gui.app.model.tabs.active;
    var snapshot = gui.app.model.panes.findConst(Session.pane_id).?.agent_thread.?.*;
    const thread = "review-thread";
    @memcpy(snapshot.thread_id[0..thread.len], thread);
    snapshot.thread_id_len = thread.len;
    snapshot.revision += 1;
    try receiveThread(session, &snapshot);
    _ = try client.runtime_messages.handleServerMessage(
        &gui.app,
        .{
            .change_review_changed = .{
                .pane_id = Session.pane_id,
                .pane_generation = 77,
                .session = thread,
                .latest_edition_id = 1,
            },
        },
    );
    try publish(session);
    try std.testing.expectEqual(@as(usize, 1), reviewControlCount(session));

    const terminal: core.PaneId = @enumFromInt(21);
    const other_terminal: core.PaneId = @enumFromInt(22);
    try data.pane_split.split(&gui.app.model, tab, .{ .existing_pane = Session.pane_id, .new_pane = terminal, .location = Session.location, .axis = .horizontal, .area = data.workbench.region(&gui.app.model).area });
    _ = gui.app.model.panes.find(terminal).?.identify(.terminal, 78);
    try data.pane_split.split(&gui.app.model, tab, .{ .existing_pane = terminal, .new_pane = other_terminal, .location = Session.location, .axis = .vertical, .area = data.workbench.region(&gui.app.model).area });
    _ = gui.app.model.panes.find(other_terminal).?.identify(.terminal, 79);
    _ = gui.app.model.tabs.layout[tab].focusPane(Session.pane_id);
    try publish(session);
    try std.testing.expectEqual(@as(usize, 1), reviewControlCount(session));
    {
        const registry = gui.widgets.dispatcher.maps.presented();
        const target = try reviewControl(session);
        try std.testing.expectEqual(Session.pane_id, target.action.change_review);
        try std.testing.expect(routing.eligible(gui, target));
        try std.testing.expectEqual(target.id, registry.at(.{ target.bounds.x + target.bounds.width / 2, target.bounds.y + target.bounds.height / 2 }).?.id);
    }

    try std.testing.expect(gui.app.model.togglePaneFullscreen(.{ .area = data.workbench.region(&gui.app.model).area }) != null);
    try publish(session);
    try std.testing.expectEqual(@as(usize, 1), reviewControlCount(session));
    _ = gui.app.model.tabs.layout[tab].focusPane(terminal);
    try publish(session);
    try std.testing.expectEqual(@as(usize, 0), reviewControlCount(session));
    try std.testing.expect(gui.app.model.togglePaneFullscreen(.{ .area = data.workbench.region(&gui.app.model).area }) != null);

    _ = try client.runtime_messages.handleServerMessage(
        &gui.app,
        .{
            .change_review_changed = .{
                .pane_id = terminal,
                .pane_generation = 78,
                .session = "terminal-thread",
                .latest_edition_id = 2,
            },
        },
    );
    try publish(session);
    try std.testing.expectEqual(@as(usize, 2), reviewControlCount(session));
}

test "agent web links use the host opener with decoded Markdown destinations" {
    const session = try agentSession();
    defer session.deinit();
    try linkSnapshot(session, "[site](https://example.com/?a=1&amp;b=2)");
    try publish(session);
    try pressControl(session, try messageLinkTarget(session));
    try std.testing.expectEqualStrings("https://example.com/?a=1&b=2", session.opened_link.?.uri());
    try std.testing.expectEqual(@as(usize, 0), session.pane_creation_count);
}

test "right clicking agent links copies destinations without opening them" {
    for ([_][]const u8{ "/tmp/a b.md", "https://example.com/?a=1&b=2", "custom:destination" }) |destination| {
        const session = try agentSession();
        defer session.deinit();
        var source: [256]u8 = undefined;
        try linkSnapshot(session, try std.fmt.bufPrint(&source, "[label](<{s}>)", .{destination}));
        try publish(session);
        const link = try messageLinkTarget(session);
        const point = .{ .x = link.bounds.x + 1, .y = link.bounds.y + link.bounds.height / 2 };
        try send(session, .{ .pointer = .{ .kind = .press, .button = .right, .x = point.x, .y = point.y } });
        try send(session, .{ .pointer = .{ .kind = .release, .button = .right, .x = point.x, .y = point.y } });
        var request: native.HostRequest = .{};
        try std.testing.expect(session.gui.host.next(&request));
        try std.testing.expectEqualStrings(destination, request.text.?[0..request.len]);
        try std.testing.expect(session.opened_link == null);
        try std.testing.expectEqual(@as(usize, 0), session.pane_creation_count);
        try std.testing.expect(!session.gui.host.next(&request));
    }
}

test "right clicking a replaced message link cannot copy the replacement" {
    const session = try agentSession();
    defer session.deinit();
    try linkSnapshot(session, "[site](https://old.example.com)");
    try publish(session);
    const link = try messageLinkTarget(session);
    try linkSnapshot(session, "[site](https://new.example.com)");
    try send(session, .{ .pointer = .{ .kind = .press, .button = .right, .x = link.bounds.x + 1, .y = link.bounds.y + link.bounds.height / 2 } });
    var request: native.HostRequest = .{};
    try std.testing.expect(!session.gui.host.next(&request));
}

test "agent link copy feedback waits for native success and ignores failures" {
    const session = try agentSession();
    defer session.deinit();
    try linkSnapshot(session, "[site](https://example.com)");
    try publish(session);
    const link = try messageLinkTarget(session);
    for ([_]bool{ false, true }) |success| {
        try send(session, .{ .pointer = .{ .kind = .press, .button = .right, .x = link.bounds.x + 1, .y = link.bounds.y + link.bounds.height / 2 } });
        try send(session, .{ .pointer = .{ .kind = .release, .button = .right, .x = link.bounds.x + 1, .y = link.bounds.y + link.bounds.height / 2 } });
        var request: native.HostRequest = .{};
        try std.testing.expect(session.gui.host.next(&request));
        try std.testing.expectEqual(@as(u64, 0), session.gui.widgets.copy_feedback.until_ns);
        try send(session, .{ .clipboard = .{ .request_id = request.request_id, .target_id = request.target_id, .generation = request.generation, .status = if (success) .success else .unavailable } });
        try std.testing.expectEqual(success, session.gui.widgets.copy_feedback.until_ns > 0);
        try std.testing.expect(session.gui.widgets.copy_feedback.pending == null);
    }
}

test "agent link hand cursor follows links and rejects stale or covered targets" {
    const session = try agentSession();
    defer session.deinit();
    for ([_][]const u8{ "[file](/tmp/file.zig)", "https://example.com", "[custom](custom:target)" }) |source| {
        try linkSnapshot(session, source);
        try publish(session);
        const link = try messageLinkTarget(session);
        try hoverMessageLink(session, link);
        try std.testing.expectEqual(.pointer, session.gui.pointer.hover.shape);
        try linkSnapshot(session, "replacement text");
        try hoverMessageLink(session, link);
        try std.testing.expect(session.gui.pointer.hover.shape != .pointer);
    }

    try linkSnapshot(session, "[site](https://example.com)");
    try publish(session);
    const link = try messageLinkTarget(session);
    session.gui.app.model.name_prompt.begin(.create_workspace);
    try hoverMessageLink(session, link);
    try std.testing.expect(session.gui.pointer.hover.shape != .pointer);
}

fn existingEditor(session: *Session, name: []const u8) !core.PaneId {
    const editor_id: core.PaneId = @enumFromInt(99);
    const tab = session.gui.app.model.tabs.active;
    try data.pane_split.split(&session.gui.app.model, tab, .{ .existing_pane = Session.pane_id, .new_pane = editor_id, .location = Session.location, .axis = .horizontal, .area = data.workbench.region(&session.gui.app.model).area });
    try std.testing.expect(session.gui.app.model.identifyPane(.{ .request_id = @enumFromInt(2), .pane_id = editor_id, .location = Session.location, .created = false, .kind = .terminal, .pane_generation = 88 }));
    _ = session.gui.app.model.panes.find(editor_id).?.setForegroundName(name);
    _ = session.gui.app.model.tabs.layout[tab].focusPane(Session.pane_id);
    return editor_id;
}

fn editorReply(session: *Session, outcome: core.EditorOpened.Outcome) !void {
    const reply: core.EditorOpened = .{ .request_id = session.last_editor_open.?.request_id, .outcome = outcome, .pane_id = @enumFromInt(99), .pane_generation = 88 };
    var buffer: [128]u8 = undefined;
    _ = try client.runtime_messages.handleServerMessage(&session.gui.app, try core.decodeServer(try core.encodeEditorOpened(&buffer, reply)));
    try session.settle();
}

test "agent file links reuse supported editors without splitting or typing into the PTY" {
    for ([_][]const u8{ "nvim", "vim", "emacs" }) |editor| {
        const session = try agentSession();
        defer session.deinit();
        session.gui.app.options.editor = editor;
        const editor_id = try existingEditor(session, editor);
        try linkSnapshot(session, "[file](/tmp/reused.md)");
        try publish(session);
        try pressControl(session, try messageLinkTarget(session));
        try session.settle();
        try std.testing.expectEqual(@as(usize, 1), session.editor_open_count);
        try std.testing.expectEqual(@as(usize, 0), session.pane_creation_count);
        try std.testing.expectEqualStrings("/tmp/reused.md", session.last_editor_open.?.path());
        try std.testing.expectEqual(Session.pane_id, session.last_editor_open.?.pane_id);
        try editorReply(session, .opened);
        const tab = session.gui.app.model.tabs.active;
        try std.testing.expectEqual(@as(usize, 2), session.gui.app.model.panes.countIn(session.gui.app.model.tabs.location[tab].tab_id));
        try std.testing.expectEqual(editor_id, session.gui.app.model.tabs.layout[tab].focused());
        try std.testing.expectEqual(@as(usize, 0), session.input_len);
        try std.testing.expectEqual(@as(usize, 0), session.pane_creation_count);
        try editorReply(session, .opened);
        try std.testing.expectEqual(@as(usize, 0), session.pane_creation_count);
    }
}

test "unavailable editor integration falls back once using the clicked editor configuration" {
    const session = try agentSession();
    defer session.deinit();
    session.gui.app.options.editor = "nvim";
    _ = try existingEditor(session, "nvim");
    try linkSnapshot(session, "[file](/tmp/fallback.md)");
    try publish(session);
    try pressControl(session, try messageLinkTarget(session));
    try session.settle();
    session.gui.app.options.editor = "nano";
    try editorReply(session, .unavailable);
    try std.testing.expectEqual(@as(usize, 1), session.pane_creation_count);
    const request = (try core.decodeClient(session.pane_creation_wire[0..session.pane_creation_len])).create_pane;
    var args = request.launch.arguments();
    try std.testing.expectEqualStrings("nvim", (try args.next()).?);
    try std.testing.expectEqualStrings("/tmp/fallback.md", (try args.next()).?);
    try editorReply(session, .unavailable);
    try std.testing.expectEqual(@as(usize, 1), session.pane_creation_count);
}

test "nano always gets a new pane and failed remote opens never duplicate an editor" {
    for ([_][]const u8{ "nano", "nvim" }) |editor| {
        const session = try agentSession();
        defer session.deinit();
        session.gui.app.options.editor = editor;
        _ = try existingEditor(session, editor);
        try linkSnapshot(session, "[file](/tmp/design.md)");
        try publish(session);
        try pressControl(session, try messageLinkTarget(session));
        try session.settle();
        if (std.mem.eql(u8, editor, "nano")) {
            try std.testing.expectEqual(@as(usize, 0), session.editor_open_count);
            try std.testing.expectEqual(@as(usize, 1), session.pane_creation_count);
        } else {
            try editorReply(session, .failed);
            try std.testing.expectEqual(@as(usize, 0), session.pane_creation_count);
            try std.testing.expect(session.gui.app.model.editor_open.pending == null);
        }
    }
}

test "editor reuse replies cannot act on a replaced source pane" {
    const session = try agentSession();
    defer session.deinit();
    session.gui.app.options.editor = "nvim";
    _ = try existingEditor(session, "nvim");
    try linkSnapshot(session, "[file](/tmp/stale.md)");
    try publish(session);
    try pressControl(session, try messageLinkTarget(session));
    try session.settle();
    try std.testing.expect(session.gui.app.model.identifyPane(.{ .request_id = @enumFromInt(3), .pane_id = Session.pane_id, .location = Session.location, .created = false, .kind = .agent, .pane_generation = 100 }));
    try editorReply(session, .unavailable);
    try std.testing.expectEqual(@as(usize, 0), session.pane_creation_count);
}

test "review hides underlying message links before delivery and restores them after closing" {
    const session = try agentSession();
    defer session.deinit();
    try linkSnapshot(session, "[site](https://example.com)");
    try publish(session);
    const link = try messageLinkTarget(session);
    try hoverMessageLink(session, link);
    try std.testing.expectEqual(.pointer, session.gui.pointer.hover.shape);
    try std.testing.expect(session.gui.widgets.message_link_preview != null);

    try session.gui.openChangeReview(Session.pane_id);
    for (0..2) |frame| {
        if (frame != 0) {
            try publish(session);
        }

        try hoverMessageLink(session, link);
        try std.testing.expectEqual(.default, session.gui.pointer.hover.shape);
        try std.testing.expect(session.gui.pointer.hover.link == null);
        try std.testing.expect(session.gui.widgets.message_link_preview == null);
        try pressControl(session, link);
        try send(session, .{ .pointer = .{ .kind = .press, .button = .right, .x = link.bounds.x + 1, .y = link.bounds.y + 1 } });
        try send(session, .{ .pointer = .{ .kind = .release, .button = .right, .x = link.bounds.x + 1, .y = link.bounds.y + 1 } });
        var request: native.HostRequest = .{};
        try std.testing.expect(!session.gui.host.next(&request));
        try std.testing.expect(session.opened_link == null);
    }

    _ = try client.runtime_messages.handleServerMessage(&session.gui.app, .{ .change_review_snapshot = .{
        .request_id = session.gui.app.model.change_review.pending.?,
        .pane_id = Session.pane_id,
        .pane_generation = 77,
        .session = "thread-A",
    } });
    session.gui.review.widget.command = .close;
    try publish(session);
    try hoverMessageLink(session, try messageLinkTarget(session));
    try std.testing.expectEqual(.pointer, session.gui.pointer.hover.shape);
    try std.testing.expect(session.gui.widgets.message_link_preview != null);
}

test "link clipboard confirmation remains visible when review opens before native completion" {
    const session = try agentSession();
    defer session.deinit();
    try linkSnapshot(session, "[site](https://example.com)");
    try publish(session);
    const link = try messageLinkTarget(session);
    try send(session, .{ .pointer = .{ .kind = .press, .button = .right, .x = link.bounds.x + 1, .y = link.bounds.y + 1 } });
    try send(session, .{ .pointer = .{ .kind = .release, .button = .right, .x = link.bounds.x + 1, .y = link.bounds.y + 1 } });
    var request: native.HostRequest = .{};
    try std.testing.expect(session.gui.host.next(&request));
    try session.gui.openChangeReview(Session.pane_id);
    try publish(session);
    const before = session.gui.renderer.quads.items().len;
    try send(session, .{ .clipboard = .{ .request_id = request.request_id, .target_id = request.target_id, .generation = request.generation, .status = .success } });
    try std.testing.expect(session.gui.widgets.copy_feedback.pending == null);
    try std.testing.expect(session.gui.widgets.copy_feedback.until_ns > 0);
    try publish(session);
    try std.testing.expect(session.gui.renderer.quads.items().len > before);
    try std.testing.expect(session.gui.chrome.animation.deadline_ns != null);
}

test "native batch routes text to a newly opened prompt and retires the composer replay target" {
    const session = try agentSession();
    defer session.deinit();
    const gui = session.gui;
    adoptAgentBinding(session, try data.config_values.ConfiguredBinding.parse(&.{"ctrl+r"}, .history_palette));
    try std.testing.expect(try gui.acceptInput(.{ .key = .{ .code = .{ .char = .init("r") }, .mods = .{ .ctrl = true } } }));
    try std.testing.expect(try gui.acceptInput(.{ .text = .{ .bytes = "x" } }));
    try input_support.pump(gui);
    try session.settle();

    try std.testing.expectEqualStrings("x", gui.app.model.name_prompt.currentConst().?.field.text());
    try std.testing.expectEqualStrings("", gui.app.model.agentPane(Session.pane_id).?.composerSlice());
    try std.testing.expect(gui.binding_target == null);
}
