//! GUI controller for widget decisions. Domain edits remain commands to the
//! existing shared prompt/application handlers; no widget mutates model fields.
const std = @import("std");
const client = @import("telar-client");
const core = @import("telar-core");
const GuiClient = @import("../../GuiClient.zig");
const Event = @import("../../input/event.zig").Event;
const Key = @import("../../input/KeyInput.zig");
const Id = @import("Id.zig");
const Target = @import("Target.zig");
const FieldView = @import("FieldView.zig");
const GenericField = client.GenericField;

/// Delivered controls may outlive their pane's keyboard focus between frames.
/// Example: `routing.reconcileFocus(gui);`
pub fn reconcileFocus(gui: *GuiClient) void {
    const state = &gui.widgets;
    const model = gui.app.model.activeTabModelConst();
    const focused_pane: ?core.PaneId = if (model) |value| value.layout.focused() else null;
    if (state.composer_menu.selector) |selector| {
        if (focused_pane != selector.pane_id) {
            state.composer_menu.selector = null;
            state.dispatcher.revision +%= 1;
        }
    }

    const target = state.dispatcher.focusedTarget() orelse return;
    const pane_id = target.paneId() orelse return;
    if (focused_pane == pane_id and eligible(gui, target)) {
        return;
    }

    state.cancelComposition();
    state.paste_owner = null;
    _ = state.dispatcher.focus(null);
    state.dispatcher.cancel();
    if (gui.input.binding_target != null) {
        gui.input.cancelBinding();
    }
}

/// Runs after queue admission, before the existing terminal fallback.
/// Targeted stale events are consumed, never retargeted to another editor.
/// Example: `if (try routing.apply(gui, event)) return;`
pub fn apply(gui: *GuiClient, event: Event) !bool {
    reconcileFocus(gui);
    @import("completions.zig").refresh(gui);
    const state = &gui.widgets;
    if (@import("image_preview.zig").route(gui, event)) {
        return true;
    }

    if (try routeAgentBinding(gui, event)) {
        return true;
    }

    const begins = event == .scroll or (event == .pointer and (event.pointer.kind == .press or event.pointer.kind == .scroll_up or event.pointer.kind == .scroll_down));
    if (begins and !@import("../../input/PointerRouting.zig").geometryMatches(&gui.app)) {
        if (event == .scroll) {
            state.thread_scroll.clear();
        }
        if (event == .pointer and event.pointer.kind == .press) {
            state.dispatcher.discardPointer(event.pointer.button);
        }

        return true;
    }

    if (event == .focus and !event.focus) {
        state.thread_scroll.clear();
        state.cancelComposition();
    }
    if (event == .clipboard and event.clipboard.operation == .write) {
        try finishCut(gui, event.clipboard);
        @import("thread_items.zig").copied(gui, event.clipboard);
        @import("thread_selection.zig").copied(gui, event.clipboard);
        return true;
    }
    if (event == .clipboard) {
        try finishPaste(gui, event.clipboard);
        return true;
    }
    if (event == .accessibility) {
        try accessibility(gui, event.accessibility);
        return true;
    }

    const leased = event == .key or (event == .text and event.text.physical != null);
    const ownership = if (leased) (if (event == .key and state.completions.open) state.dispatcher.editorKey(event.key) else state.dispatcher.route(event)) else null;
    const result = ownership orelse state.dispatcher.route(event);
    if (try @import("completions.zig").route(gui, event, result)) {
        return true;
    }
    if (try @import("composer_menu.zig").route(gui, event, result)) {
        return true;
    }

    if (explicitTarget(event)) |id| {
        if (ownership) |decision| {
            if (!decision.consumed) {
                return false;
            }

            if (decision.target == null or !decision.target.?.id.eql(id)) {
                return true;
            }
        }

        const target = state.dispatcher.maps.presented().find(id) orelse return true;
        const focused = state.dispatcher.focused orelse return true;
        if (!focused.eql(id) or field(gui, target) == null) {
            return true;
        }

        try editor(gui, target, event);
        return true;
    }

    if (event == .pointer and result.consumed) {
        const capture = state.dispatcher.captures[0];
        const captured = if (capture) |id| state.dispatcher.maps.presented().find(id) else null;
        gui.chrome.widgetPointer(event.pointer, captured != null and captured.?.action == .resize_sidebar);
        gui.input.pointer.hover.observe(event.pointer);
        gui.input.pointer.hover.refresh(gui);
    }
    if (result.focus_changed) {
        if (state.thread_selection.owner) |owner| {
            const focused = state.dispatcher.focusedTarget();
            if (focused == null or focused.?.action != .transcript or focused.?.action.transcript != owner.pane_id) {
                @import("thread_selection.zig").cancel(gui);
            }
        }
        state.cancelComposition();
        if (state.dispatcher.focusedTarget()) |target| {
            try focus(gui, target);
        }
    }

    if (event == .scroll or (event == .pointer and (event.pointer.kind == .scroll_up or event.pointer.kind == .scroll_down))) {
        if (try scroll(gui, event)) {
            return true;
        }
    }

    if (try @import("tab_drag.zig").apply(gui, event, result.target)) {
        return true;
    }

    if (try @import("thread_selection.zig").route(gui, event, result)) {
        return true;
    }

    const target = result.target orelse return result.consumed;
    if (!eligible(gui, target)) {
        return true;
    }

    switch (target.action) {
        .text_field, .composer => try editor(gui, target, event),
        .transcript, .message_link, .composer_completion => {},
        .agent_control, .composer_selector, .composer_choice, .thread_item => {
            if (target.action == .thread_item and try threadItemKey(gui, target, event)) {
                return true;
            }

            if (target.enabled and buttonActivated(event, target)) {
                try activateControl(gui, target);
            }
        },
        .intent => |intent| {
            if (activated(event)) {
                var value = intent;
                if (event == .pointer and event.pointer.button != .left) {
                    value = if (event.pointer.button == .right and intent == .select_tab) .{ .rename_tab = intent.select_tab } else .none;
                }

                try dispatchIntent(gui, value);
            }
        },
        .complete_path => {
            if (target.enabled) {
                try scrollDirectory(gui, target, event);
                if (buttonActivated(event, target)) {
                    try activateControl(gui, target);
                }
            }
        },
        .prompt, .history => {
            if (target.enabled and buttonActivated(event, target)) {
                try activateControl(gui, target);
            }
        },
        .resize_sidebar => {
            if (event == .pointer and event.pointer.button == .left and (event.pointer.kind == .drag or event.pointer.kind == .release)) {
                gui.adoptSidebarWidth(@intFromFloat(@max(1, @min(65535, @floor(event.pointer.x) + 1))));
            }
        },
        .custom => {},
    }

    return result.consumed;
}

/// Latches paste ownership once, including when a control merely consumes it.
/// Example: `const owned = try routing.beginPaste(gui);`
pub fn beginPaste(gui: *GuiClient) !bool {
    reconcileFocus(gui);
    const state = &gui.widgets;
    if (state.image_preview != null) {
        state.paste_consumed = true;
        state.paste_owner = null;
        return true;
    }

    const routed = state.dispatcher.route(.{ .paste = "" });
    state.paste_consumed = routed.consumed;
    state.paste_owner = if (routed.target) |target| if (field(gui, target) != null) target.id else null else null;
    state.paste_buffer = .{ .multiline = if (routed.target) |target| target.action == .composer else false };
    state.paste_revision = editingRevision(gui);
    if (routed.target) |target| {
        if (field(gui, target)) |value| {
            state.paste_selection = value.selection();
        }
    }

    return state.paste_consumed;
}

/// Example: `try routing.paste(gui, bytes);`
pub fn paste(gui: *GuiClient, bytes: []const u8) !void {
    const owner = gui.widgets.paste_owner orelse return;
    const target = gui.widgets.dispatcher.maps.presented().find(owner) orelse return;
    if (field(gui, target) == null) {
        return;
    }

    gui.widgets.paste_buffer.append(bytes);
}

/// Example: `try routing.endPaste(gui);`
pub fn endPaste(gui: *GuiClient) !void {
    reconcileFocus(gui);
    defer gui.widgets.paste_owner = null;
    defer gui.widgets.paste_consumed = false;
    const owner = gui.widgets.paste_owner orelse return;
    const target = gui.widgets.dispatcher.maps.presented().find(owner) orelse return;
    if (field(gui, target) != null and FieldView.revision(&gui.app, target) == gui.widgets.paste_revision) {
        if (gui.widgets.paste_buffer.text()) |bytes| {
            try focus(gui, target);
            try command(gui, .{ .replace_range = .{ .range = gui.widgets.paste_selection, .text = bytes } });
        }
    }
}

fn explicitTarget(event: Event) ?Id {
    return switch (event) {
        .text => |value| if (value.target_id == 0) null else .{ .target_id = value.target_id, .generation = value.generation },
        .key => |value| if (value.target_id == 0) null else .{ .target_id = value.target_id, .generation = value.generation },
        .composition => |value| .{ .target_id = value.target_id, .generation = value.generation },
        .clipboard => |value| if (value.target_id == 0) null else .{ .target_id = value.target_id, .generation = value.generation },
        .delete_surrounding => |value| .{ .target_id = value.target_id, .generation = value.generation },
        else => null,
    };
}

fn field(gui: *const GuiClient, target: Target) ?FieldView {
    return FieldView.captureClient(&gui.app, target);
}

fn editingRevision(gui: *const GuiClient) u64 {
    if (gui.widgets.dispatcher.focusedTarget()) |target| {
        if (target.action == .composer and !gui.app.model.name_prompt.active()) {
            return FieldView.revision(&gui.app, target);
        }
    }

    return gui.app.model.name_prompt.version();
}

fn routeAgentBinding(gui: *GuiClient, event: Event) !bool {
    const key: client.Key = switch (event) {
        .key => |value| value.terminalKey(),
        .text => |value| blk: {
            if (value.physical == null or value.bytes.len == 0 or value.bytes.len > 4 or gui.widgets.preedit.owner != null) {
                return false;
            }

            var result: client.Key = .{ .code = .{ .char = .{ .bytes = @splat(0), .len = @intCast(value.bytes.len) } }, .phase = value.phase, .physical = value.physical };
            @memcpy(result.code.char.bytes[0..value.bytes.len], value.bytes);
            break :blk result;
        },
        else => return false,
    };
    const owner = if (key.physical) |physical| gui.widgets.dispatcher.keys.owner(physical) else null;
    if (key.phase != .press) {
        if (owner == null or owner.? != .fallback) {
            return false;
        }

        if (key.phase == .release) {
            _ = gui.widgets.dispatcher.keys.release(key.physical.?);
        }

        // A binding may replace its composer with a tab or modal before keyUp.
        // Existing fallback leases still complete through their original router.
        var handler: @import("../../input/InputHandler.zig") = .{ .app = &gui.app };
        gui.input.stopped = try gui.input.router.routeEvent(.{ .key = key, .raw = "", .now_ns = client.monotonic(gui.app.io) }, &handler) == .stop;
        return true;
    }

    if (!gui.widgets.dispatcher.window_focused or gui.widgets.dispatcher.maps.presented().modal_layer != 0 or gui.widgets.composer_menu.selector != null or gui.widgets.completions.open or client.controllers.key_routing.captures(&gui.app)) {
        return false;
    }

    const target = gui.widgets.dispatcher.focusedTarget() orelse return false;
    switch (target.action) {
        .composer, .transcript, .composer_selector, .agent_control, .thread_item => {},
        else => return false,
    }
    if (target.layer != 0 or !eligible(gui, target) or (event == .key and event.key.mods.super)) {
        return false;
    }
    if (explicitTarget(event)) |id| {
        if (!id.eql(target.id)) {
            return false;
        }
    }

    if (!gui.input.router.wantsBinding(key)) {
        return false;
    }
    if (key.physical) |physical| {
        if (!gui.widgets.dispatcher.keys.acquire(physical, .fallback)) {
            return true;
        }
    }

    if (gui.input.router.bindingDeadline() == null and !gui.input.router.prefixPending()) {
        gui.input.binding_target = target.id;
    }

    gui.widgets.cancelComposition();
    var handler: @import("../../input/InputHandler.zig") = .{ .app = &gui.app, .widget_target = gui.input.binding_target };
    gui.input.stopped = try gui.input.router.routeEvent(.{ .key = key, .raw = "", .now_ns = client.monotonic(gui.app.io) }, &handler) == .stop;
    return true;
}

/// Replays an unmatched or expired chord only to its original live composer.
/// Held keys return to widget ownership before ordinary repeat/release routing.
/// Example: `try routing.replayBindingKey(gui, owner, key);`
pub fn replayBindingKey(gui: *GuiClient, owner: Id, key: client.Key) !void {
    const target = gui.widgets.dispatcher.focusedTarget();
    const model = gui.app.model.activeTabModelConst();
    const valid = gui.widgets.dispatcher.window_focused and gui.widgets.dispatcher.maps.presented().modal_layer == 0 and gui.widgets.composer_menu.selector == null and target != null and target.?.id.eql(owner) and target.?.action == .composer and model != null and model.?.layout.focused() == target.?.action.composer and field(gui, target.?) != null;
    if (key.physical) |physical| {
        gui.input.router.relinquishKey(physical);
        const lease = gui.widgets.dispatcher.keys.owner(physical);
        if (lease != null and lease.? == .fallback) {
            _ = gui.widgets.dispatcher.keys.acquire(physical, if (valid) .{ .widget = owner } else .discarded);
        }
    }

    if (!valid) {
        return;
    }

    const input: Key = .{ .code = key.code, .mods = .{ .shift = key.mods.shift, .alt = key.mods.alt, .ctrl = key.mods.ctrl }, .phase = key.phase, .physical = key.physical, .kitty = key.kitty };
    if (!try shortcut(gui, target.?, input)) {
        try composerKey(gui, target.?, input);
    }
}

fn composerKey(gui: *GuiClient, target: Target, key: Key) !void {
    const value: client.ModelNamePromptCommand = switch (key.code) {
        .enter => {
            if (key.mods.shift) {
                try command(gui, .{ .insert = "\n" });
            } else {
                gui.widgets.thread_anchor.cancel(target.action.composer);
                try @import("completions.zig").submit(gui, target.action.composer);
            }

            return;
        },
        .backspace => .backspace,
        .delete => .delete,
        .left => .{ .move_left = key.mods.shift },
        .right => .{ .move_right = key.mods.shift },
        .home => .{ .home = key.mods.shift },
        .end => .{ .end = key.mods.shift },
        .up, .down => {
            const current = field(gui, target) orelse return;
            const geometry = gui.widgets.editors.presented().find(target.id) orelse return;
            const layout: @import("MultilineLayout.zig") = .{ .text = current.text, .head = current.head, .columns = geometry.columns, .rows = @intFromFloat(@max(1, @floor(geometry.bounds.height / geometry.line_height))), .font = geometry.font };
            const caret = layout.position(current.head);
            const row = if (key.code == .up) caret[1] -| 1 else caret[1] + 1;
            var full = layout;
            full.rows = std.math.maxInt(u32);
            const offset = full.offset(.{ @floatFromInt(caret[0]), @floatFromInt(row) });
            try command(gui, .{ .select_range = .{ if (key.mods.shift) current.anchor else offset, offset } });
            return;
        },
        .page_up, .page_down => {
            try @import("thread_scroll.zig").input(gui, threadScrollTarget(gui, target), .{ .delta_y = if (key.code == .page_up) -12 else 12 });
            return;
        },
        .escape => .cancel,
        .char => |character| {
            if (key.mods.ctrl or key.mods.alt or key.mods.super) {
                return;
            }

            try command(gui, .{ .insert = character.bytes[0..character.len] });
            return;
        },
        else => return,
    };

    try command(gui, value);
}

/// Validates a delivered control against the current attachment and modal owner.
/// Example: `if (!routing.eligible(gui, target)) return;`
pub fn eligible(gui: *const GuiClient, target: Target) bool {
    if (target.action == .agent_control and target.action.agent_control.kind == .close_image) {
        const preview = gui.widgets.image_preview orelse return false;
        return target.layer == 1 and target.id.generation == preview.generation and target.action.agent_control.pane_id == preview.control.pane_id;
    }

    if (target.action == .composer_completion) {
        return @import("completions.zig").eligible(gui, target);
    }

    if (target.action == .thread_item) {
        return @import("thread_items.zig").eligible(gui, target);
    }

    if (target.action == .composer_selector or target.action == .composer_choice) {
        return @import("composer_menu.zig").eligible(gui, target);
    }

    if (gui.app.model.name_prompt.currentConst()) |prompt| {
        return target.layer != 0 and target.id.generation == prompt.generation;
    }

    const pane_id = switch (target.action) {
        .composer => |id| id,
        .transcript => |id| id,
        .agent_control => |control| control.pane_id,
        .message_link => |control| control.owner.pane_id,
        else => return target.layer == 0,
    };
    const model = gui.app.model.activeTabModelConst() orelse return false;
    const pane = model.findConst(pane_id) orelse return false;
    return target.layer == 0 and pane.attached and pane.kind == .agent and pane.attachment_generation == target.id.generation;
}

fn focus(gui: *GuiClient, target: Target) !void {
    gui.input.cancelBinding();
    if (target.paneId()) |pane_id| {
        if (!eligible(gui, target)) {
            return;
        }
        if (target.action == .composer and field(gui, target) == null) {
            return;
        }

        _ = gui.widgets.dispatcher.focus(target.id);
        const model = gui.app.model.activeTabModel() orelse return;
        _ = try client.controllers.view_interactions.apply(&gui.app, model, .{ .intent = .{ .focus_pane = pane_id }, .consumed = true });
        return;
    }

    if (target.action == .text_field and field(gui, target) != null) {
        try command(gui, .{ .focus_field = if (target.action.text_field == .directory) .directory else .name });
    }
}

fn command(gui: *GuiClient, value: client.ModelNamePromptCommand) !void {
    const revision = editingRevision(gui);
    if (!gui.app.model.name_prompt.active()) {
        if (gui.widgets.dispatcher.focusedTarget()) |target| {
            if (target.action == .composer and field(gui, target) != null) {
                try client.agent_threads.edit(&gui.app, target.action.composer, value);
                if (revision != editingRevision(gui)) {
                    gui.widgets.cancelComposition();
                }

                return;
            }
        }
    }

    _ = try client.controllers.name_prompts.handleInput(&gui.app, .{ .command = value });
    if (revision != editingRevision(gui) or value == .select_all or value == .select_range or value == .replace_range) {
        gui.widgets.cancelComposition();
    }
}

fn editor(gui: *GuiClient, target: Target, event: Event) !void {
    // Modifier changes can arrive as stationary pointer motion over an editor.
    // Only selection gestures may focus it and cancel a pending key sequence.
    if (event == .pointer and (event.pointer.button != .left or (event.pointer.kind != .press and event.pointer.kind != .drag))) {
        return;
    }

    if ((event == .key and event.key.phase == .release) or (event == .text and event.text.phase == .release)) {
        return;
    }

    if ((event == .key and event.key.phase == .repeat) or (event == .text and event.text.phase == .repeat)) {
        const focused = gui.widgets.dispatcher.focused orelse return;
        if (!focused.eql(target.id)) {
            return;
        }
    }

    const current = field(gui, target) orelse return;
    const state = &gui.widgets;
    try focus(gui, target);
    switch (event) {
        .key => |key| {
            if (key.phase == .release) {
                return;
            }

            if (try shortcut(gui, target, key)) {
                return;
            }

            if (key.code == .escape and state.preedit.owner != null) {
                state.cancelComposition();
                state.dispatcher.revision +%= 1;
                return;
            }

            const revision = editingRevision(gui);
            if (target.action == .composer) {
                try composerKey(gui, target, key);
            } else {
                _ = try client.controllers.name_prompts.handleInput(&gui.app, .{ .key = key.terminalKey() });
            }
            if (revision != editingRevision(gui)) {
                state.cancelComposition();
            }
        },
        .text => |value| {
            if (value.phase == .release) {
                return;
            }

            const range = if (value.replacement_start != std.math.maxInt(u32)) [2]u32{ value.replacement_start, value.replacement_end } else if (state.preedit.owner != null and state.preedit.owner.?.eql(target.id)) state.preedit.replacement else current.selection();
            try command(gui, .{ .replace_range = .{ .range = range, .text = value.bytes } });
            state.cancelComposition();
            state.dispatcher.revision +%= 1;
        },
        .paste => |bytes| {
            var buffer: @import("PasteBuffer.zig") = .{ .multiline = target.action == .composer };
            buffer.append(bytes);
            if (buffer.text()) |text| {
                try command(gui, .{ .replace_range = .{ .range = current.selection(), .text = text } });
            }
        },
        .composition => |value| {
            state.preedit.update(target.id, .{ .composition = value, .current = current }) catch return;
            state.dispatcher.revision +%= 1;
        },
        .delete_surrounding => |value| {
            if (value.before > current.head or value.after > current.text.len - current.head) {
                return;
            }

            try command(gui, .{ .replace_range = .{ .range = .{ current.head - value.before, current.head + value.after }, .text = "" } });
            state.cancelComposition();
        },
        .pointer => |pointer| {
            if (pointer.button == .left and (pointer.kind == .press or pointer.kind == .drag)) {
                const geometry = state.editors.presented().find(target.id) orelse return;
                if (geometry.multiline) {
                    const layout: @import("MultilineLayout.zig") = .{ .text = current.text, .head = current.head, .columns = geometry.columns, .rows = @intFromFloat(@max(1, @floor(geometry.bounds.height / geometry.line_height))), .font = geometry.font };
                    const offset = layout.offset(.{ (pointer.x - geometry.bounds.x) / geometry.cell_width, (pointer.y - geometry.bounds.y) / geometry.line_height });
                    const anchor = if (pointer.kind == .drag or pointer.mods & 1 != 0) current.anchor else offset;
                    state.cancelComposition();
                    try command(gui, .{ .select_range = .{ anchor, offset } });
                    return;
                }

                var copy: GenericField(4096) = .init(current.text);
                _ = copy.selectRange(.{ current.anchor, current.head });
                const visible = copy.view(geometry.columns);
                const column = @max(0, (pointer.x - geometry.bounds.x) / geometry.cell_width);
                var offset: u32 = @intCast(copy.scroll);
                var used: f64 = 0;
                var iterator: core.GraphemeIterator = .{ .bytes = visible.text };
                while (iterator.next()) |cluster| {
                    const width: f64 = @floatFromInt(core.measure(cluster.bytes));
                    if (column < used + width / 2) {
                        break;
                    }

                    used += width;
                    offset += @intCast(cluster.bytes.len);
                }

                const anchor = if (pointer.kind == .drag or pointer.mods & 1 != 0) current.anchor else offset;
                state.cancelComposition();
                try command(gui, .{ .select_range = .{ anchor, offset } });
            }
        },
        else => {},
    }
}

fn shortcut(gui: *GuiClient, target: Target, key: Key) !bool {
    if (key.code != .char or key.code.char.len != 1 or (!key.mods.ctrl and !key.mods.super)) {
        return false;
    }

    const current = field(gui, target) orelse return true;
    const selected = current.selection();
    if (key.phase != .press) {
        return true;
    }

    switch (std.ascii.toLower(key.code.char.bytes[0])) {
        'a' => try command(gui, .select_all),
        'c' => gui.requestClipboardWrite(current.text[selected[0]..selected[1]]) catch return true,
        'x' => {
            try beginCut(gui, target, selected);
        },
        'v' => gui.requestClipboardRead(target.id.target_id, target.id.generation) catch return true,
        else => return false,
    }

    return true;
}

fn activated(event: Event) bool {
    return switch (event) {
        .pointer => |value| value.kind == .press,
        .key => |value| value.phase == .press and (value.code == .enter or (value.code == .char and value.code.char.len == 1 and value.code.char.bytes[0] == ' ')),
        else => false,
    };
}

fn buttonActivated(event: Event, target: Target) bool {
    return switch (event) {
        .pointer => |pointer| pointer.kind == .release and pointer.button == .left and target.contains(.{ pointer.x, pointer.y }),
        .key => activated(event),
        else => false,
    };
}

fn threadItemKey(gui: *GuiClient, target: Target, event: Event) !bool {
    if (event != .key or event.key.phase == .release) {
        return false;
    }

    const key = event.key;
    switch (key.code) {
        .page_up, .page_down => {
            try @import("thread_scroll.zig").input(gui, threadScrollTarget(gui, target), .{ .delta_y = if (key.code == .page_up) -12 else 12 });
            return true;
        },
        .escape => {
            const registry = gui.widgets.dispatcher.maps.presented();
            for (registry.targets[0..registry.len]) |item| {
                if (item.action == .composer and item.action.composer == target.action.thread_item.pane_id and item.id.generation == target.id.generation) {
                    try focus(gui, item);
                    break;
                }
            }

            return true;
        },
        .char => |character| {
            if ((key.mods.super or key.mods.ctrl) and character.len == 1 and std.ascii.toLower(character.bytes[0]) == 'c') {
                if (key.phase == .press and target.action.thread_item.operation != .toggle_work) {
                    var copy = target;
                    copy.action.thread_item.operation = .copy;
                    try @import("thread_items.zig").activate(gui, copy);
                }

                return true;
            }
        },
        else => {},
    }

    return false;
}

fn scrollDirectory(gui: *GuiClient, target: Target, event: Event) !void {
    const pointer_scroll = event == .pointer and (event.pointer.kind == .scroll_up or event.pointer.kind == .scroll_down);
    if (event != .scroll and !pointer_scroll) {
        return;
    }

    const completion = &gui.app.model.path_completion;
    if (completion.version() != target.action.complete_path.revision or completion.pending != .none) {
        return;
    }

    const remainder = &gui.widgets.directory_scroll_remainder;
    if (event == .scroll and (event.scroll.phase == .begin or event.scroll.phase == .cancel)) {
        remainder.* = 0;
    }
    if (event == .scroll and event.scroll.phase == .cancel) {
        return;
    }

    remainder.* += if (event == .scroll) event.scroll.delta_y / (if (event.scroll.precise) @max(1, @as(f64, target.bounds.height)) else 1) else if (event.pointer.kind == .scroll_up) -1 else 1;
    const steps: usize = @intFromFloat(@min(64, @abs(@trunc(remainder.*))));
    const forward = remainder.* > 0;
    remainder.* -= @trunc(remainder.*);
    for (0..steps) |_| {
        try command(gui, if (forward) .move_down else .move_up);
    }
}

fn activateControl(gui: *GuiClient, target: Target) !void {
    gui.widgets.cancelComposition();
    switch (target.action) {
        .composer_completion => try @import("completions.zig").activate(gui, target),
        .composer_selector, .composer_choice => try @import("composer_menu.zig").activate(gui, target),
        .thread_item => {
            try focus(gui, target);
            try @import("thread_items.zig").activate(gui, target);
        },
        .agent_control => |control| switch (control.kind) {
            .preview_image => @import("image_preview.zig").open(gui, target),
            .close_image => @import("image_preview.zig").close(gui),
            .remove_image => client.agent_threads.removeImage(&gui.app, control.pane_id, .{ .index = control.image_index, .revision = control.composer_revision }),
            .submit => {
                gui.widgets.thread_anchor.cancel(control.pane_id);
                try @import("completions.zig").submit(gui, control.pane_id);
            },
            .interrupt => try client.agent_threads.interrupt(&gui.app, control.pane_id),
            .approve, .decline => try client.agent_threads.approve(&gui.app, .{ .pane_id = control.pane_id, .approval_id = control.approval_id, .accept = control.kind == .approve }),
            .review => {
                const pane = gui.app.model.agentPane(control.pane_id) orelse return;
                const thread = pane.agent_thread orelse return;
                const request = thread.pending_approval orelse return;
                if (request.id != control.approval_id) {
                    return;
                }

                const value: @import("AgentReview.zig") = .{ .pane_id = control.pane_id, .generation = target.id.generation, .approval_id = control.approval_id };
                const closing = if (gui.widgets.approval_review) |review| std.meta.eql(review, value) else false;
                gui.widgets.approval_review = if (closing) null else value;
                gui.widgets.thread_anchor.cancel(control.pane_id);
                gui.widgets.dispatcher.revision +%= 1;
                try client.agent_threads.scroll(&gui.app, control.pane_id, if (closing) -65536 else 65536);
            },
        },
        .prompt => |action| try command(gui, if (action == .submit) .submit else .cancel),
        .complete_path => |choice| try client.controllers.name_prompts.chooseDirectory(&gui.app, choice.index, choice.revision),
        .history => |action| {
            const prompt = gui.app.model.name_prompt.currentConst() orelse return;
            if (prompt.target() != .history) {
                return;
            }

            switch (action) {
                .select => |choice| try client.controllers.name_prompts.selectHistoryRow(&gui.app, choice.index, choice.revision),
                .submit => |choice| {
                    const history = &gui.app.model.history_palette;
                    if (history.phase == .ready and history.version() == choice.revision and prompt.selection() == choice.index) {
                        try command(gui, .submit);
                    }
                },
                .cycle_scope => try command(gui, .tab),
                .toggle_inspection => try command(gui, .toggle_inspection),
            }
        },
        .intent => |intent| try dispatchIntent(gui, intent),
        else => {},
    }
}

fn dispatchIntent(gui: *GuiClient, intent: client.Intent) !void {
    const model = gui.app.model.activeTabModel() orelse return;
    _ = try client.controllers.view_interactions.apply(&gui.app, model, .{ .intent = intent, .consumed = true });
    _ = gui.widgets.dispatcher.focus(null);
}

fn scroll(gui: *GuiClient, event: Event) !bool {
    if (!gui.focused) {
        return true;
    }

    if (gui.app.model.name_prompt.currentConst()) |prompt| {
        return if (prompt.target() == .history) try scrollHistory(gui, event) else false;
    }

    if (event == .scroll and try @import("thread_scroll.zig").captured(gui, event.scroll)) {
        return true;
    }

    const pointer = if (event == .scroll) [2]f64{ event.scroll.x, event.scroll.y } else [2]f64{ event.pointer.x, event.pointer.y };
    if (gui.widgets.dispatcher.maps.presented().at(pointer)) |hit| {
        if (hit.action == .transcript or hit.action == .composer or hit.action == .thread_item or hit.action == .message_link) {
            const target = threadScrollTarget(gui, hit);
            if (!eligible(gui, target)) {
                return true;
            }

            const input: @import("../../input/ScrollEvent.zig") = if (event == .scroll) event.scroll else .{ .delta_y = if (event.pointer.kind == .scroll_up) -1 else 1 };
            try @import("thread_scroll.zig").input(gui, target, input);

            return true;
        }
    }

    if (!@import("../Bands.zig").within(gui.chrome.presented().bands.sidebar, pointer[0], pointer[1])) {
        return false;
    }

    const sidebar = gui.chrome.sidebarScrollAt(pointer) orelse return true;
    if (event == .scroll and (event.scroll.phase == .begin or event.scroll.phase == .cancel)) {
        sidebar.resetGesture();
    }
    if (event == .scroll and event.scroll.phase == .cancel) {
        return true;
    }

    const delta = if (event == .scroll) std.math.clamp(event.scroll.delta_y, -65535, 65535) * (if (event.scroll.precise) @as(f64, 1) else @as(f64, @floatFromInt(sidebar.step))) else if (event.pointer.kind == .scroll_up) -@as(f64, @floatFromInt(sidebar.step)) else @as(f64, @floatFromInt(sidebar.step));
    if (sidebar.scrollBy(delta)) {
        gui.chrome.invalidate();
    }

    return true;
}

fn threadScrollTarget(gui: *const GuiClient, target: Target) Target {
    const pane_id = switch (target.action) {
        .thread_item => |control| control.pane_id,
        .message_link => |control| control.owner.pane_id,
        .composer => |id| id,
        else => return target,
    };
    const registry = gui.widgets.dispatcher.maps.presented();
    for (registry.targets[0..registry.len]) |item| {
        if (item.action == .transcript and item.action.transcript == pane_id and item.id.generation == target.id.generation) {
            return item;
        }
    }

    return target;
}

/// Routes a pane scroll binding through the delivered transcript's wheel policy.
/// Example: `_ = try routing.scrollFocusedThread(gui, .up);`
pub fn scrollFocusedThread(gui: *GuiClient, direction: client.ScrollDirection) !bool {
    const model = gui.app.model.activeTabModelConst() orelse return false;
    const pane = model.focusedPaneConst() orelse return false;
    if (pane.kind != .agent) {
        return false;
    }

    const registry = gui.widgets.dispatcher.maps.presented();
    for (registry.targets[0..registry.len]) |target| {
        if (target.action == .transcript and target.action.transcript == pane.id and eligible(gui, target)) {
            try @import("thread_scroll.zig").input(gui, target, .{ .delta_y = if (direction == .up) -3 else 3 });
            break;
        }
    }

    return true;
}

fn scrollHistory(gui: *GuiClient, event: Event) !bool {
    const prompt = gui.app.model.name_prompt.currentConst() orelse return true;
    const state = &gui.widgets;
    const history = &gui.app.model.history_palette;
    if (history.phase != .ready) {
        state.history_scroll_remainder = 0;
        return true;
    }

    const bounds = gui.overlays.presented().native_modal orelse return true;
    const pointer = if (event == .scroll) [2]f64{ event.scroll.x, event.scroll.y } else [2]f64{ event.pointer.x, event.pointer.y };
    if (!@import("../Bands.zig").within(bounds, pointer[0], pointer[1])) {
        return true;
    }

    var delivered = false;
    var line_height: f64 = @floatFromInt(@max(1, gui.input.pointer.geometry.size.cell_height_px));
    const registry = state.dispatcher.maps.presented();
    for (registry.targets[0..registry.len]) |target| {
        if (target.id.generation != prompt.generation) {
            continue;
        }

        if (target.action == .text_field) {
            delivered = true;
        }

        if (target.action == .history and target.action.history == .select) {
            if (target.action.history.select.revision != history.version()) {
                return true;
            }

            if (!prompt.inspecting()) {
                line_height = @max(1, target.bounds.height);
            }
        }
    }

    if (!delivered) {
        return true;
    }

    if (state.history_scroll_generation != prompt.generation or state.history_scroll_inspecting != prompt.inspecting() or (event == .scroll and (event.scroll.phase == .begin or event.scroll.phase == .cancel))) {
        state.history_scroll_remainder = 0;
        state.history_scroll_generation = prompt.generation;
        state.history_scroll_inspecting = prompt.inspecting();
    }

    if (event == .scroll and event.scroll.phase == .cancel) {
        return true;
    }

    const delta = if (event == .scroll) event.scroll.delta_y / (if (event.scroll.precise) line_height else 1) else if (event.pointer.kind == .scroll_up) @as(f64, -1) else @as(f64, 1);
    if (!std.math.isFinite(delta)) {
        return true;
    }

    state.history_scroll_remainder += std.math.clamp(delta, -32, 32);
    const lines: i16 = @intFromFloat(std.math.clamp(@trunc(state.history_scroll_remainder), -32, 32));
    state.history_scroll_remainder -= @floatFromInt(lines);
    if (lines == 0) {
        return true;
    }

    if (prompt.inspecting()) {
        try client.controllers.name_prompts.scrollHistoryInspection(&gui.app, lines);
    } else {
        for (0..@abs(lines)) |_| {
            if (history.phase != .ready) {
                break;
            }

            try command(gui, if (lines < 0) .move_up else .move_down);
        }
    }

    return true;
}

fn accessibility(gui: *GuiClient, value: @import("../../input/AccessibilityAction.zig")) !void {
    const target = gui.widgets.dispatcher.maps.presented().find(.{ .target_id = value.target_id, .generation = value.generation }) orelse return;
    if (gui.widgets.composer_menu.selector != null and target.action != .composer_selector and target.action != .composer_choice) {
        return;
    }

    if (!target.enabled or target.layer < gui.widgets.dispatcher.maps.presented().modal_layer or !eligible(gui, target)) {
        return;
    }

    if (value.revision != 0 and value.revision != FieldView.revision(&gui.app, target)) {
        return;
    }

    switch (value.action) {
        .focus => {
            _ = gui.widgets.dispatcher.focus(target.id);
            try focus(gui, target);
        },
        .press => if (target.activatable()) {
            try activateControl(gui, target);
        },
        .set_value, .set_selection => {
            const current = field(gui, target) orelse return;
            _ = gui.widgets.dispatcher.focus(target.id);
            try focus(gui, target);
            if (value.action == .set_value) {
                try command(gui, .{ .replace_range = .{ .range = .{ 0, @intCast(current.text.len) }, .text = value.text } });
            } else {
                try command(gui, .{ .select_range = .{ value.selection_start, value.selection_end } });
            }
        },
        .replace_range => {
            const current = field(gui, target) orelse return;
            const range: [2]u32 = .{ value.replacement_start, value.replacement_end };
            if (value.revision != FieldView.revision(&gui.app, target) or range[0] > range[1] or !current.validRange(range)) {
                return;
            }

            _ = gui.widgets.dispatcher.focus(target.id);
            try focus(gui, target);
            try command(gui, .{ .replace_range = .{ .range = range, .text = value.text } });
        },
        .increment, .decrement => {},
        .copy, .cut, .paste => {
            const current = field(gui, target) orelse return;
            if (value.selection_start > value.selection_end or !current.validRange(.{ value.selection_start, value.selection_end })) {
                return;
            }

            _ = gui.widgets.dispatcher.focus(target.id);
            try focus(gui, target);

            if (value.action == .paste) {
                try command(gui, .{ .select_range = .{ value.selection_start, value.selection_end } });
                gui.requestClipboardRead(target.id.target_id, target.id.generation) catch return;
            } else if (value.action == .cut) {
                try beginCut(gui, target, .{ value.selection_start, value.selection_end });
            } else {
                gui.requestClipboardWrite(current.text[value.selection_start..value.selection_end]) catch return;
            }
        },
    }
}

fn beginCut(gui: *GuiClient, target: Target, range: [2]u32) !void {
    const current = field(gui, target) orelse return;
    for (&gui.widgets.pending_cuts) |*slot| {
        if (slot.* != null) {
            continue;
        }

        const request_id = gui.requestClipboardWriteOwned(.{ .target_id = target.id.target_id, .generation = target.id.generation }, current.text[range[0]..range[1]]) catch return;
        slot.* = .{ .request_id = request_id, .owner = target.id, .range = range, .revision = FieldView.revision(&gui.app, target) };
        return;
    }
}

/// Retains the exact editable revision before asynchronous system clipboard I/O.
/// Example: `try routing.beginClipboardRead(gui, target.id);`
pub fn beginClipboardRead(gui: *GuiClient, owner: Id) !void {
    const target = gui.widgets.dispatcher.maps.presented().find(owner) orelse return;
    const current = field(gui, target) orelse return;
    if (target.action == .composer and gui.widgets.pastingImage(target.action.composer)) {
        return;
    }

    for (&gui.widgets.pending_pastes) |*slot| {
        if (slot.* != null) {
            continue;
        }

        const request_owner: @import("../../host/Owner.zig") = .{ .target_id = owner.target_id, .generation = owner.generation };
        const request_id = if (target.action == .composer) try gui.host.readImage(request_owner) else try gui.host.read(request_owner);
        slot.* = .{ .request_id = request_id, .owner = owner, .range = current.selection(), .revision = FieldView.revision(&gui.app, target) };
        gui.widgets.dispatcher.revision +%= 1;
        @import("../../native/native.zig").telar_gui_wake(gui.driver.fds[1]);
        return;
    }

    return error.HostRequestsFull;
}

fn finishPaste(gui: *GuiClient, result: @import("../../input/ClipboardResult.zig")) !void {
    const owner: Id = .{ .target_id = result.target_id, .generation = result.generation };
    for (&gui.widgets.pending_pastes) |*slot| {
        const pending = slot.* orelse continue;
        if (pending.request_id != result.request_id or !pending.owner.eql(owner)) {
            continue;
        }

        slot.* = null;
        gui.widgets.dispatcher.revision +%= 1;
        if (!gui.widgets.dispatcher.window_focused or gui.widgets.composer_menu.selector != null or gui.widgets.image_preview != null) {
            return;
        }

        const focused = gui.widgets.dispatcher.focused orelse return;
        const target = gui.widgets.dispatcher.maps.presented().find(owner) orelse return;
        if (!focused.eql(owner) or !eligible(gui, target) or pending.revision != FieldView.revision(&gui.app, target)) {
            return;
        }

        if (result.status != .success) {
            if (result.status == .too_large or result.status == .cancelled) {
                try client.controllers.notifications.publishNow(&gui.app, .{ .level = .warning, .title = "Clipboard could not be pasted", .message = if (result.status == .too_large) "The clipboard image or attachment storage exceeds its size limit." else "The clipboard image could not be read or saved." });
            }

            return;
        }

        if (result.image) {
            if (target.action == .composer) {
                try client.agent_threads.attachImage(&gui.app, target.action.composer, result.text);
            }

            return;
        }

        const current = field(gui, target) orelse return;
        if (!current.validRange(pending.range)) {
            return;
        }

        var buffer: @import("PasteBuffer.zig") = .{ .multiline = target.action == .composer };
        buffer.append(result.text);
        if (buffer.text()) |text| {
            try command(gui, .{ .replace_range = .{ .range = pending.range, .text = text } });
        }

        return;
    }
}

fn finishCut(gui: *GuiClient, result: @import("../../input/ClipboardResult.zig")) !void {
    const id: Id = .{ .target_id = result.target_id, .generation = result.generation };
    for (&gui.widgets.pending_cuts) |*slot| {
        const cut = slot.* orelse continue;
        if (cut.request_id != result.request_id or !cut.owner.eql(id)) {
            continue;
        }

        slot.* = null;
        const focused = gui.widgets.dispatcher.focused orelse return;
        if (!focused.eql(id)) {
            return;
        }

        const target = gui.widgets.dispatcher.maps.presented().find(id) orelse return;
        if (result.status != .success or cut.revision != FieldView.revision(&gui.app, target)) {
            return;
        }
        if (field(gui, target) == null or !eligible(gui, target)) {
            return;
        }

        try focus(gui, target);
        try command(gui, .{ .replace_range = .{ .range = cut.range, .text = "" } });
        return;
    }
}
