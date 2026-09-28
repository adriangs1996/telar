//! GUI controller for widget decisions. Domain edits remain commands to the
//! existing shared prompt/application handlers; no widget mutates model fields.
const textfield = @import("textfield");
const keyinput = @import("keyinput");
const pacing = @import("pacing");
const cellgrid = @import("cellgrid");
const tab_drag = @import("tab_drag.zig");
const Bands = @import("../Bands.zig");
const native = @import("../../native/native.zig");
const event_module = @import("../../input/event.zig");
const data = @import("model");
const std = @import("std");
const client = @import("telar-client");
const core = @import("telar-core");
const GuiAdapter = @import("../../GuiAdapter.zig");
const Key = @import("../../input/KeyInput.zig");
const Id = @import("Id.zig");
const Target = @import("Target.zig");
const FieldView = @import("FieldView.zig");
const PasteBuffer = @import("PasteBuffer.zig");
const AccessibilityAction = @import("../../input/AccessibilityAction.zig");
const Owner = @import("../../host/Owner.zig");
const ClipboardResult = @import("../../input/ClipboardResult.zig");
const GenericField = textfield.GenericField;

/// Delivered controls may outlive their pane's keyboard focus between frames.
/// Example: `routing.reconcileFocus(gui);`
pub fn reconcileFocus(gui: *GuiAdapter) void {
    const state = &gui.widgets;
    const focused_pane: ?core.PaneId = if (gui.app.model.tabs.activeSlot()) |tab| gui.app.model.tabs.layout[tab].focused() else null;
    const target = state.dispatcher.focusedTarget() orelse return;
    const pane_id = target.paneId() orelse return;

    if (focused_pane == pane_id and eligible(gui, target)) {
        return;
    }

    state.cancelComposition();
    state.paste_owner = null;
    _ = state.dispatcher.focus(null);
    state.dispatcher.cancel();
}

/// Runs after queue admission, before the existing terminal fallback.
/// Targeted stale events are consumed, never retargeted to another editor.
/// Example: `if (try routing.apply(gui, event)) return;`
pub fn apply(gui: *GuiAdapter, event: event_module.Event) !bool {
    reconcileFocus(gui);
    const state = &gui.widgets;

    if (try continueFallback(gui, event)) {
        return true;
    }

    if (event.isScrollOrPointerBegin() and !gui.pointerGeometryMatches()) {
        if (event.isPointerPress()) {
            state.dispatcher.discardPointer(event.pointer.button);
        }

        return true;
    }

    if (event.isFocusNotFocused()) {
        state.cancelComposition();
    }

    if (event.isWriteClipboardContent()) {
        try finishCut(gui, event.clipboard);
        return true;
    }

    if (event.isClipboard()) {
        try finishPaste(gui, event.clipboard);
        return true;
    }

    if (event.isAccessibility()) {
        try accessibility(gui, event.accessibility);
        return true;
    }

    const leased = event == .key or (event == .text and event.text.physical != null);
    const ownership = if (leased) state.dispatcher.route(event) else null;
    const result = ownership orelse state.dispatcher.route(event);

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
        gui.pointer.hover.observe(event.pointer);
        gui.pointer.hover.refresh(gui);
    }
    if (result.focus_changed) {
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

    if (try tab_drag.apply(gui, event, result.target)) {
        return true;
    }

    const target = result.target orelse return result.consumed;
    if (!eligible(gui, target)) {
        return true;
    }

    switch (target.action) {
        .text_field => try editor(gui, target, event),
        .change_review => {
            if (target.enabled and buttonActivated(event, target)) {
                try activateControl(gui, target);
            }
        },
        .intent => |intent| {
            if (activated(event)) {
                var value = intent;
                if (event == .pointer and event.pointer.button != .left) {
                    value = if (event.pointer.button == .right) client.secondaryIntent(intent) else .none;
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
        .preview => |action| {
            if (buttonActivated(event, target)) {
                showPreview(gui, action);
            }
        },
        .custom => {},
    }

    return result.consumed;
}

/// Latches paste ownership once, including when a control merely consumes it.
/// Example: `const owned = try routing.beginPaste(gui);`
pub fn beginPaste(gui: *GuiAdapter) !bool {
    reconcileFocus(gui);
    const state = &gui.widgets;
    const routed = state.dispatcher.route(.{ .paste = "" });
    state.paste_consumed = routed.consumed;
    state.paste_owner = if (routed.target) |target| if (field(gui, target) != null) target.id else null else null;
    state.paste_buffer = .{};
    state.paste_revision = editingRevision(gui);
    if (routed.target) |target| {
        if (field(gui, target)) |value| {
            state.paste_selection = value.selection();
        }
    }

    return state.paste_consumed;
}

/// Example: `try routing.paste(gui, bytes);`
pub fn paste(gui: *GuiAdapter, bytes: []const u8) !void {
    const owner = gui.widgets.paste_owner orelse return;
    const target = gui.widgets.dispatcher.maps.presented().find(owner) orelse return;
    if (field(gui, target) == null) {
        return;
    }

    gui.widgets.paste_buffer.append(bytes);
}

/// Example: `try routing.endPaste(gui);`
pub fn endPaste(gui: *GuiAdapter) !void {
    reconcileFocus(gui);
    defer gui.widgets.paste_owner = null;
    defer gui.widgets.paste_consumed = false;
    const owner = gui.widgets.paste_owner orelse return;
    const target = gui.widgets.dispatcher.maps.presented().find(owner) orelse return;
    if (field(gui, target) != null and FieldView.revision(gui.app) == gui.widgets.paste_revision) {
        if (gui.widgets.paste_buffer.text()) |bytes| {
            try focus(gui, target);
            try command(gui, .{ .replace_range = .{ .range = gui.widgets.paste_selection, .text = bytes } });
        }
    }
}

fn explicitTarget(event: event_module.Event) ?Id {
    return switch (event) {
        .text => |value| if (value.target_id == 0) null else .{ .target_id = value.target_id, .generation = value.generation },
        .key => |value| if (value.target_id == 0) null else .{ .target_id = value.target_id, .generation = value.generation },
        .composition => |value| .{ .target_id = value.target_id, .generation = value.generation },
        .clipboard => |value| if (value.target_id == 0) null else .{ .target_id = value.target_id, .generation = value.generation },
        .delete_surrounding => |value| .{ .target_id = value.target_id, .generation = value.generation },
        else => null,
    };
}

fn field(gui: *const GuiAdapter, target: Target) ?FieldView {
    return FieldView.captureClient(gui.app, target);
}

fn editingRevision(gui: *const GuiAdapter) u64 {
    return gui.app.model.name_prompt.version();
}

/// Completes held terminal input before a modal consumes newly pressed keys.
/// Example: `if (try routing.continueFallback(gui, event)) return true;`
pub fn continueFallback(gui: *GuiAdapter, event: event_module.Event) !bool {
    const key: keyinput.Key = switch (event) {
        .key => |value| if (value.phase == .press) return false else value.terminalKey(),
        .text => |value| blk: {
            if (value.phase == .press or value.physical == null or value.bytes.len == 0 or value.bytes.len > 4) {
                return false;
            }

            var result: keyinput.Key = .{
                .code = .{
                    .char = .{
                        .bytes = @splat(0),
                        .len = @intCast(value.bytes.len),
                    },
                },
                .phase = value.phase,
                .physical = value.physical,
            };
            @memcpy(result.code.char.bytes[0..value.bytes.len], value.bytes);
            break :blk result;
        },
        else => return false,
    };
    const physical = key.physical orelse return false;
    const owner = gui.widgets.dispatcher.keys.owner(physical) orelse return false;
    if (owner != .fallback) {
        return false;
    }

    if (key.phase == .release) {
        _ = gui.widgets.dispatcher.keys.release(physical);
    }

    _ = try gui.routeKey(.{ .key = key, .raw = "", .now_ns = pacing.clock.monotonic(gui.app.io) });
    return true;
}

/// Validates a delivered control against the current attachment and modal owner.
/// Example: `if (!routing.eligible(gui, target)) return;`
pub fn eligible(gui: *const GuiAdapter, target: Target) bool {
    if (gui.app.model.name_prompt.currentConst()) |prompt| {
        return target.layer != 0 and target.id.generation == prompt.generation;
    }

    const pane_id = switch (target.action) {
        .change_review => |id| id,
        else => return target.layer == 0,
    };
    const tab = gui.app.model.tabs.activeSlot() orelse return false;
    const pane = gui.app.model.panes.findInConst(gui.app.model.tabs.location[tab].tab_id, pane_id) orelse return false;
    return target.layer == 0 and pane.attached and pane.hasChangeReview() and pane.attachment_generation == target.id.generation;
}

fn focus(gui: *GuiAdapter, target: Target) !void {
    gui.cancelBinding();
    if (target.paneId()) |pane_id| {
        if (!eligible(gui, target)) {
            return;
        }

        _ = gui.widgets.dispatcher.focus(target.id);
        const tab = gui.app.model.tabs.activeSlot() orelse return;
        _ = try client.view_interactions.apply(gui.app, tab, .{ .intent = .{ .focus_pane = pane_id }, .consumed = true });
        return;
    }

    if (target.action == .text_field and field(gui, target) != null) {
        try command(gui, .{ .focus_field = if (target.action.text_field == .directory) .directory else .name });
    }
}

fn command(gui: *GuiAdapter, value: data.name_prompt.Command) !void {
    const revision = editingRevision(gui);
    _ = try client.name_prompt.inputPrompt(
        gui.app,
        .{
            .command = value,
        },
    );
    if (revision != editingRevision(gui) or value == .select_all or value == .select_range or value == .replace_range) {
        gui.widgets.cancelComposition();
    }
}

fn editor(gui: *GuiAdapter, target: Target, event: event_module.Event) !void {
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
            _ = try client.name_prompt.inputPrompt(
                gui.app,
                .{
                    .key = key.terminalKey(),
                },
            );
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
            var buffer: PasteBuffer = .{};
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
                var copy: GenericField(4096) = .init(current.text);
                _ = copy.selectRange(.{ current.anchor, current.head });
                const visible = copy.view(geometry.columns);
                const column = @max(0, (pointer.x - geometry.bounds.x) / geometry.cell_width);
                var offset: u32 = @intCast(copy.scroll);
                var used: f64 = 0;
                var iterator: cellgrid.GraphemeIterator = .{ .bytes = visible.text };
                while (iterator.next()) |cluster| {
                    const width: f64 = @floatFromInt(cellgrid.text.measure(cluster.bytes));
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

fn shortcut(gui: *GuiAdapter, target: Target, key: Key) !bool {
    // ⌘⌫ deletes the selected history command, as it removes a Finder item.
    if (key.code == .backspace and key.mods.super and (historyPrompt(gui) or machineList(gui))) {
        if (key.phase == .press) {
            try command(gui, .remove_entry);
        }

        return true;
    }
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
        // With nothing selected in the search field, copy takes the
        // selected command instead of an empty string.
        'c' => if (selected[0] == selected[1] and historyPrompt(gui)) try command(gui, .copy_entry) else gui.requestClipboardWrite(current.text[selected[0]..selected[1]]) catch return true,
        'x' => {
            try beginCut(gui, target, selected);
        },
        'v' => gui.requestClipboardRead(target.id.target_id, target.id.generation) catch return true,
        else => return false,
    }

    return true;
}

fn machineList(gui: *const GuiAdapter) bool {
    const prompt = gui.app.model.name_prompt.currentConst() orelse return false;
    return prompt.paletteMode() == .machines;
}

fn historyPrompt(gui: *const GuiAdapter) bool {
    const prompt = gui.app.model.name_prompt.currentConst() orelse return false;
    return prompt.target() == .history;
}

fn activated(event: event_module.Event) bool {
    return switch (event) {
        .pointer => |value| value.kind == .press,
        .key => |value| value.phase == .press and (value.code == .enter or (value.code == .char and value.code.char.len == 1 and value.code.char.bytes[0] == ' ')),
        else => false,
    };
}

fn buttonActivated(event: event_module.Event, target: Target) bool {
    return switch (event) {
        .pointer => |pointer| pointer.kind == .release and pointer.button == .left and target.contains(.{ pointer.x, pointer.y }),
        .key => activated(event),
        else => false,
    };
}

fn scrollDirectory(gui: *GuiAdapter, target: Target, event: event_module.Event) !void {
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

fn activateControl(gui: *GuiAdapter, target: Target) !void {
    gui.widgets.cancelComposition();
    switch (target.action) {
        .change_review => |pane_id| try gui.openChangeReview(pane_id),
        .prompt => |action| try command(gui, if (action == .submit) .submit else .cancel),
        .complete_path => |choice| try client.name_prompt.chooseDirectory(gui.app, choice.index, choice.revision),
        .history => |action| {
            const prompt = gui.app.model.name_prompt.currentConst() orelse return;
            if (prompt.target() != .history) {
                return;
            }

            switch (action) {
                .select => |choice| try client.history_palette.selectHistoryRow(gui.app, choice.index, choice.revision),
                .submit, .submit_alternate => |choice| {
                    const history = &gui.app.model.history_palette;
                    if (history.phase == .ready and history.version() == choice.revision and prompt.selection() == choice.index) {
                        try command(gui, if (action == .submit) .submit else .submit_alternate);
                    }
                },
                .cycle_scope => try command(gui, .tab),
                .select_scope => |scope| try command(gui, .{ .select_scope = scope }),
                .select_author => |author| try command(gui, .{ .select_author = author }),
                .toggle_failed => try command(gui, .toggle_failed),
                .toggle_inspection => try command(gui, .toggle_inspection),
                .page_older => try command(gui, .page_up),
                .copy => try command(gui, .copy_entry),
                .remove => try command(gui, .remove_entry),
                .visit_pane => try command(gui, .visit_pane),
            }
        },
        .intent => |intent| try dispatchIntent(gui, intent),
        .preview => |action| showPreview(gui, action),
        else => {},
    }
}

/// Opens a preview in the modal or closes it; a press inside the modal only
/// keeps it from reaching what lies behind.
fn showPreview(gui: *GuiAdapter, action: Target.PreviewAction) void {
    switch (action) {
        .open => |id| gui.previews.openModal(id),
        .close => gui.previews.closeModal(),
        .hold => {},
    }
}

fn dispatchIntent(gui: *GuiAdapter, intent: client.Intent) !void {
    const tab = gui.app.model.tabs.activeSlot() orelse return;
    _ = try client.view_interactions.apply(gui.app, tab, .{ .intent = intent, .consumed = true });
    _ = gui.widgets.dispatcher.focus(null);
}

fn scroll(gui: *GuiAdapter, event: event_module.Event) !bool {
    if (!gui.focused) {
        return true;
    }

    if (gui.app.model.name_prompt.currentConst()) |prompt| {
        return if (prompt.target() == .history) try scrollHistory(gui, event) else false;
    }

    const pointer = if (event == .scroll) [2]f64{ event.scroll.x, event.scroll.y } else [2]f64{ event.pointer.x, event.pointer.y };
    if (!Bands.within(gui.chrome.presented().bands.sidebar, pointer[0], pointer[1])) {
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

fn scrollHistory(gui: *GuiAdapter, event: event_module.Event) !bool {
    const prompt = gui.app.model.name_prompt.currentConst() orelse return true;
    const state = &gui.widgets;
    const history = &gui.app.model.history_palette;
    if (history.phase != .ready) {
        state.history_scroll_remainder = 0;
        return true;
    }

    const bounds = gui.overlays.presented().native_modal orelse return true;
    const pointer = if (event == .scroll) [2]f64{ event.scroll.x, event.scroll.y } else [2]f64{ event.pointer.x, event.pointer.y };
    if (!Bands.within(bounds, pointer[0], pointer[1])) {
        return true;
    }

    var delivered = false;
    var line_height: f64 = @floatFromInt(@max(1, gui.pointer.geometry.size.cell_height_px));
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
        try client.history_palette.scrollHistoryInspection(gui.app, lines);
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

fn accessibility(gui: *GuiAdapter, value: AccessibilityAction) !void {
    const target = gui.widgets.dispatcher.maps.presented().find(.{ .target_id = value.target_id, .generation = value.generation }) orelse return;
    if (!target.enabled or target.layer < gui.widgets.dispatcher.maps.presented().modal_layer or !eligible(gui, target)) {
        return;
    }

    if (value.revision != 0 and value.revision != FieldView.revision(gui.app)) {
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
            if (value.revision != FieldView.revision(gui.app) or range[0] > range[1] or !current.validRange(range)) {
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

fn beginCut(gui: *GuiAdapter, target: Target, range: [2]u32) !void {
    const current = field(gui, target) orelse return;
    for (&gui.widgets.pending_cuts) |*slot| {
        if (slot.* != null) {
            continue;
        }

        const request_id = gui.requestClipboardWriteOwned(.{ .target_id = target.id.target_id, .generation = target.id.generation }, current.text[range[0]..range[1]]) catch return;
        slot.* = .{ .request_id = request_id, .owner = target.id, .range = range, .revision = FieldView.revision(gui.app) };
        return;
    }
}

/// Retains the exact editable revision before asynchronous system clipboard I/O.
/// Example: `try routing.beginClipboardRead(gui, target.id);`
pub fn beginClipboardRead(gui: *GuiAdapter, owner: Id) !void {
    const target = gui.widgets.dispatcher.maps.presented().find(owner) orelse return;
    const current = field(gui, target) orelse return;
    for (&gui.widgets.pending_pastes) |*slot| {
        if (slot.* != null) {
            continue;
        }

        const request_owner: Owner = .{ .target_id = owner.target_id, .generation = owner.generation };
        const request_id = try gui.host.read(request_owner);
        slot.* = .{ .request_id = request_id, .owner = owner, .range = current.selection(), .revision = FieldView.revision(gui.app) };
        gui.widgets.dispatcher.revision +%= 1;
        native.telar_gui_wake(gui.driver.fds[1]);
        return;
    }

    return error.HostRequestsFull;
}

fn finishPaste(gui: *GuiAdapter, result: ClipboardResult) !void {
    const owner: Id = .{ .target_id = result.target_id, .generation = result.generation };
    for (&gui.widgets.pending_pastes) |*slot| {
        const pending = slot.* orelse continue;
        if (pending.request_id != result.request_id or !pending.owner.eql(owner)) {
            continue;
        }

        slot.* = null;
        gui.widgets.dispatcher.revision +%= 1;
        if (!gui.widgets.dispatcher.window_focused) {
            return;
        }

        const focused = gui.widgets.dispatcher.focused orelse return;
        const target = gui.widgets.dispatcher.maps.presented().find(owner) orelse return;
        if (!focused.eql(owner) or !eligible(gui, target) or pending.revision != FieldView.revision(gui.app)) {
            return;
        }

        if (result.status != .success) {
            if (result.status == .too_large or result.status == .cancelled) {
                try client.notifications.publishNotificationNow(
                    gui.app,
                    .{
                        .level = .warning,
                        .title = "Clipboard could not be pasted",
                        .message = if (result.status == .too_large) "The clipboard image or attachment storage exceeds its size limit." else "The clipboard image could not be read or saved.",
                    },
                );
            }

            return;
        }

        const current = field(gui, target) orelse return;
        if (!current.validRange(pending.range)) {
            return;
        }

        var buffer: PasteBuffer = .{};
        buffer.append(result.text);
        if (buffer.text()) |text| {
            try command(gui, .{ .replace_range = .{ .range = pending.range, .text = text } });
        }

        return;
    }
}

fn finishCut(gui: *GuiAdapter, result: ClipboardResult) !void {
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
        if (result.status != .success or cut.revision != FieldView.revision(gui.app)) {
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
