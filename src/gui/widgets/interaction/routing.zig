//! GUI controller for widget decisions. Domain edits remain commands to the
//! existing shared prompt/application handlers; no widget mutates model fields.
const std = @import("std");
const client = @import("telar-client");
const core = @import("telar-core");
const GuiClient = @import("../../GuiClient.zig");
const Event = @import("../../input/event.zig").Event;
const Key = @import("../../input/KeyInput.zig");
const Pointer = @import("../../input/PointerEvent.zig");
const Id = @import("Id.zig");
const Target = @import("Target.zig");
const FieldView = @import("FieldView.zig");
const GenericField = client.GenericField;

/// Runs after queue admission, before the existing terminal fallback.
/// Targeted stale events are consumed, never retargeted to another editor.
/// Example: `if (try routing.apply(gui, event)) return;`
pub fn apply(gui: *GuiClient, event: Event) !bool {
    const state = &gui.widgets;
    const begins = event == .scroll or (event == .pointer and (event.pointer.kind == .press or event.pointer.kind == .scroll_up or event.pointer.kind == .scroll_down));
    if (begins and !@import("../../input/PointerRouting.zig").geometryMatches(&gui.app)) {
        if (event == .pointer and event.pointer.kind == .press) {
            state.dispatcher.discardPointer(event.pointer.button);
        }

        return true;
    }

    if (event == .focus and !event.focus) {
        state.cancelComposition();
    }
    if (event == .clipboard and event.clipboard.operation == .write) {
        try finishCut(gui, event.clipboard);
        return true;
    }
    if (event == .accessibility) {
        try accessibility(gui, event.accessibility);
        return true;
    }

    const leased = event == .key or (event == .text and event.text.physical != null);
    const ownership = if (leased) state.dispatcher.route(event) else null;
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

    const result = ownership orelse state.dispatcher.route(event);
    if (event == .pointer and result.consumed) {
        const capture = state.dispatcher.captures[0];
        const captured = if (capture) |id| state.dispatcher.maps.presented().find(id) else null;
        gui.chrome.widgetPointer(event.pointer, captured != null and captured.?.action == .resize_sidebar);
        gui.input.pointer.hover.observe(event.pointer);
        gui.input.pointer.hover.refresh(gui);
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

    const target = result.target orelse return result.consumed;
    if (!eligible(gui, target)) {
        return true;
    }

    switch (target.action) {
        .text_field => try editor(gui, target, event),
        .intent => |intent| {
            if (activated(event)) {
                var value = intent;
                if (event == .pointer and event.pointer.button != .left) {
                    value = if (event.pointer.button == .right and intent == .select_tab) .{ .rename_tab = intent.select_tab } else .none;
                }

                try dispatchIntent(gui, value);
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
    const state = &gui.widgets;
    const routed = state.dispatcher.route(.{ .paste = "" });
    state.paste_consumed = routed.consumed;
    state.paste_owner = if (routed.target) |target| if (target.action == .text_field and field(gui, target) != null) target.id else null else null;
    state.paste_buffer = .{};
    state.paste_revision = gui.app.model.name_prompt.version();
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
    defer gui.widgets.paste_owner = null;
    defer gui.widgets.paste_consumed = false;
    const owner = gui.widgets.paste_owner orelse return;
    const target = gui.widgets.dispatcher.maps.presented().find(owner) orelse return;
    if (field(gui, target) != null and gui.app.model.name_prompt.version() == gui.widgets.paste_revision) {
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
    const prompt = gui.app.model.name_prompt.currentConst() orelse return null;
    return FieldView.capture(prompt, target);
}

fn eligible(gui: *const GuiClient, target: Target) bool {
    if (gui.app.model.name_prompt.currentConst()) |prompt| {
        return target.layer != 0 and target.id.generation == prompt.generation;
    }

    return target.layer == 0;
}

fn focus(gui: *GuiClient, target: Target) !void {
    gui.input.router.cancelSequence();
    if (target.action == .text_field and field(gui, target) != null) {
        try command(gui, .{ .focus_field = if (target.action.text_field == .directory) .directory else .name });
    }
}

fn command(gui: *GuiClient, value: client.ModelNamePromptCommand) !void {
    const revision = gui.app.model.name_prompt.version();
    _ = try client.controllers.name_prompts.handleInput(&gui.app, .{ .command = value });
    if (revision != gui.app.model.name_prompt.version() or value == .select_all or value == .select_range or value == .replace_range) {
        gui.widgets.cancelComposition();
    }
}

fn editor(gui: *GuiClient, target: Target, event: Event) !void {
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

            const revision = gui.app.model.name_prompt.version();
            _ = try client.controllers.name_prompts.handleInput(&gui.app, .{ .key = key.terminalKey() });
            if (revision != gui.app.model.name_prompt.version()) {
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
            var buffer: @import("PasteBuffer.zig") = .{};
            buffer.append(bytes);
            if (buffer.text()) |text| {
                try command(gui, .{ .replace_range = .{ .range = current.selection(), .text = text } });
            }
        },
        .clipboard => |value| {
            if (value.status == .success) {
                try editor(gui, target, .{ .paste = value.text });
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

fn dispatchIntent(gui: *GuiClient, intent: client.Intent) !void {
    const model = gui.app.model.activeTabModel() orelse return;
    _ = try client.controllers.view_interactions.apply(&gui.app, model, .{ .intent = intent, .consumed = true });
    _ = gui.widgets.dispatcher.focus(null);
}

fn scroll(gui: *GuiClient, event: Event) !bool {
    if (gui.app.model.name_prompt.active()) {
        return false;
    }

    const pointer = if (event == .scroll) [2]f64{ event.scroll.x, event.scroll.y } else [2]f64{ event.pointer.x, event.pointer.y };
    if (!@import("../../chrome/Bands.zig").within(gui.chrome.presented().bands.sidebar, pointer[0], pointer[1])) {
        return false;
    }

    const sidebar = &gui.chrome.sidebar;
    if (event == .scroll and (event.scroll.phase == .begin or event.scroll.phase == .cancel)) {
        gui.widgets.sidebar_scroll_remainder = 0;
    }
    if (event == .scroll and event.scroll.phase == .cancel) {
        return true;
    }

    const delta = if (event == .scroll) std.math.clamp(event.scroll.delta_y, -65535, 65535) * (if (event.scroll.precise) @as(f64, 1) else @as(f64, @floatFromInt(sidebar.step))) else if (event.pointer.kind == .scroll_up) -@as(f64, @floatFromInt(sidebar.step)) else @as(f64, @floatFromInt(sidebar.step));
    gui.widgets.sidebar_scroll_remainder += delta;
    const movement = @trunc(gui.widgets.sidebar_scroll_remainder);
    gui.widgets.sidebar_scroll_remainder -= movement;
    if (sidebar.scrollBy(movement)) {
        gui.chrome.invalidate();
    }

    return true;
}

fn accessibility(gui: *GuiClient, value: @import("../../input/AccessibilityAction.zig")) !void {
    const target = gui.widgets.dispatcher.maps.presented().find(.{ .target_id = value.target_id, .generation = value.generation }) orelse return;
    if (!target.enabled or target.layer < gui.widgets.dispatcher.maps.presented().modal_layer or !eligible(gui, target)) {
        return;
    }

    if (value.revision != 0 and value.revision != gui.app.model.name_prompt.version()) {
        return;
    }

    switch (value.action) {
        .focus => {
            _ = gui.widgets.dispatcher.focus(target.id);
            try focus(gui, target);
        },
        .press => if (target.action == .intent) {
            try dispatchIntent(gui, target.action.intent);
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
            if (value.revision != gui.app.model.name_prompt.version() or range[0] > range[1] or !current.validRange(range)) {
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
        slot.* = .{ .request_id = request_id, .owner = target.id, .range = range, .revision = gui.app.model.name_prompt.version() };
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
        if (result.status != .success or cut.revision != gui.app.model.name_prompt.version()) {
            return;
        }

        const target = gui.widgets.dispatcher.maps.presented().find(id) orelse return;
        if (field(gui, target) == null or !eligible(gui, target)) {
            return;
        }

        try focus(gui, target);
        try command(gui, .{ .replace_range = .{ .range = cut.range, .text = "" } });
        return;
    }
}
