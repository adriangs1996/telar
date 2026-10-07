//! GUI controller for widget decisions. Domain edits remain commands to the
//! existing shared prompt/application handlers; no widget mutates model fields.

const window_input = @import("../../window_input.zig");
const Window = @import("telar-window");
const Bands = @import("../Bands.zig");
const native = @import("../../native/native.zig");
const event_module = Window;
const data = @import("model");
const std = @import("std");
const client = @import("telar-client");
const WindowModel = @import("../../WindowModel.zig");
pub const Key = @FieldType(Window.Input, "key");
const Id = @import("Id.zig");
const Target = @import("Target.zig");
const FieldView = @import("FieldView.zig");
pub const AccessibilityAction = @FieldType(Window.Input, "accessibility");
pub const ClipboardResult = @FieldType(Window.Input, "clipboard");

/// Latches paste ownership once, including when a control merely consumes it.
/// Example: `const owned = try routing.beginPaste(gui);`
pub fn beginPaste(model: *WindowModel, app: *client.Client) !bool {
    const state = &model.widgets;
    const routed = state.dispatcher.route(.{ .paste = "" });
    state.paste_consumed = routed.consumed;
    state.paste_owner = if (routed.target) |target| if (field(app, target) != null) target.id else null else null;
    state.paste_buffer = .{};
    state.paste_revision = editingRevision(app);
    if (routed.target) |target| {
        if (field(app, target)) |value| {
            state.paste_selection = value.selection();
        }
    }

    return state.paste_consumed;
}

/// Example: `try routing.paste(gui, bytes);`
pub fn paste(model: *WindowModel, app: *client.Client, bytes: []const u8) !void {
    const owner = model.widgets.paste_owner orelse return;
    const target = model.widgets.dispatcher.maps.presented().find(owner) orelse return;
    if (field(app, target) == null) {
        return;
    }

    model.widgets.paste_buffer.append(bytes);
}

pub fn explicitTarget(event: event_module.Input) ?Id {
    return switch (event) {
        .text => |value| if (value.target_id == 0) null else .{ .target_id = value.target_id, .generation = value.generation },
        .key => |value| if (value.target_id == 0) null else .{ .target_id = value.target_id, .generation = value.generation },
        .composition => |value| .{ .target_id = value.target_id, .generation = value.generation },
        .clipboard => |value| if (value.target_id == 0) null else .{ .target_id = value.target_id, .generation = value.generation },
        .delete_surrounding => |value| .{ .target_id = value.target_id, .generation = value.generation },
        else => null,
    };
}

pub fn field(app: *const client.Client, target: Target) ?FieldView {
    return FieldView.captureClient(app, target);
}

pub fn editingRevision(app: *const client.Client) u64 {
    return app.model.name_prompt.version();
}

/// Validates a delivered control against the current attachment and modal owner.
/// Example: `if (!routing.eligible(gui, target)) return;`
pub fn eligible(app: *const client.Client, target: Target) bool {
    if (app.model.name_prompt.currentConst()) |prompt| {
        return target.layer != 0 and target.id.generation == prompt.generation;
    }

    return target.layer == 0;
}

pub fn focus(model: *WindowModel, app: *client.Client, target: Target) !void {
    window_input.cancelBinding(model);

    if (target.action == .text_field and field(app, target) != null) {
        try command(model, app, .{ .focus_field = if (target.action.text_field == .directory) .directory else .name });
    }
}

pub fn command(model: *WindowModel, app: *client.Client, value: data.name_prompt.Command) !void {
    const revision = editingRevision(app);
    _ = try client.name_prompt.inputPrompt(
        app,
        .{
            .command = value,
        },
    );
    if (revision != editingRevision(app) or value == .select_all or value == .select_range or value == .replace_range) {
        model.widgets.cancelComposition();
    }
}

pub fn machineList(app: *const client.Client) bool {
    const prompt = app.model.name_prompt.currentConst() orelse return false;
    return prompt.paletteMode() == .machines;
}

pub fn historyPrompt(app: *const client.Client) bool {
    const prompt = app.model.name_prompt.currentConst() orelse return false;
    return prompt.target() == .history;
}

pub fn activated(event: event_module.Input) bool {
    return switch (event) {
        .pointer => |value| value.kind == .press,
        .key => |value| value.phase == .press and (value.code == .enter or (value.code == .char and value.code.char.len == 1 and value.code.char.bytes[0] == ' ')),
        else => false,
    };
}

pub fn buttonActivated(event: event_module.Input, target: Target) bool {
    return switch (event) {
        .pointer => |pointer| pointer.kind == .release and pointer.button == .left and target.contains(.{ pointer.x, pointer.y }),
        .key => activated(event),
        else => false,
    };
}

pub fn scrollDirectory(model: *WindowModel, app: *client.Client, target: Target, event: event_module.Input) !void {
    const pointer_scroll = event == .pointer and (event.pointer.kind == .scroll_up or event.pointer.kind == .scroll_down);
    if (event != .scroll and !pointer_scroll) {
        return;
    }

    const completion = &app.model.path_completion;
    if (completion.version() != target.action.complete_path.revision or completion.pending != .none) {
        return;
    }

    const remainder = &model.widgets.directory_scroll_remainder;
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
        try command(model, app, if (forward) .move_down else .move_up);
    }
}

pub fn scroll(model: *WindowModel, app: *client.Client, event: event_module.Input) !bool {
    if (!model.focused) {
        return true;
    }

    if (app.model.name_prompt.currentConst()) |prompt| {
        if (prompt.target() == .history) {
            return try scrollHistory(model, app, event);
        }
        if (prompt.target() == .palette or prompt.target() == .pick) {
            return try scrollPalette(model, app, event);
        }

        return false;
    }

    const pointer = if (event == .scroll) [2]f64{ event.scroll.x, event.scroll.y } else [2]f64{ event.pointer.x, event.pointer.y };
    if (!Bands.within(model.chrome.presented().bands.sidebar, pointer[0], pointer[1])) {
        return false;
    }

    const sidebar = model.chrome.sidebarScrollAt(pointer) orelse return true;
    if (event == .scroll and (event.scroll.phase == .begin or event.scroll.phase == .cancel)) {
        sidebar.resetGesture();
    }
    if (event == .scroll and event.scroll.phase == .cancel) {
        return true;
    }

    const delta = if (event == .scroll) std.math.clamp(event.scroll.delta_y, -65535, 65535) * (if (event.scroll.precise) @as(f64, 1) else @as(f64, @floatFromInt(sidebar.step))) else if (event.pointer.kind == .scroll_up) -@as(f64, @floatFromInt(sidebar.step)) else @as(f64, @floatFromInt(sidebar.step));
    if (sidebar.scrollBy(delta)) {
        model.chrome.invalidate();
    }

    return true;
}

fn scrollPalette(model: *WindowModel, app: *client.Client, event: event_module.Input) !bool {
    const prompt = app.model.name_prompt.currentConst() orelse return true;
    const bounds = model.overlays.presented().native_modal orelse return true;
    const pointer = if (event == .scroll) [2]f64{ event.scroll.x, event.scroll.y } else [2]f64{ event.pointer.x, event.pointer.y };
    const hits = &model.overlays.presented().palette;
    if (!Bands.within(bounds, pointer[0], pointer[1]) or !hits.native or hits.count == 0) {
        return true;
    }

    const state = &model.widgets;
    if (state.palette_scroll_generation != prompt.generation or (event == .scroll and (event.scroll.phase == .begin or event.scroll.phase == .cancel))) {
        state.palette_scroll_remainder = 0;
        state.palette_scroll_generation = prompt.generation;
    }
    if (event == .scroll and event.scroll.phase == .cancel) {
        return true;
    }

    const delta = if (event == .scroll) event.scroll.delta_y / (if (event.scroll.precise) @max(1, @as(f64, hits.pixel_rows[0].height)) else 1) else if (event.pointer.kind == .scroll_up) @as(f64, -1) else @as(f64, 1);
    if (!std.math.isFinite(delta)) {
        return true;
    }

    state.palette_scroll_remainder += std.math.clamp(delta, -32, 32);
    const lines: i16 = @intFromFloat(std.math.clamp(@trunc(state.palette_scroll_remainder), -32, 32));
    state.palette_scroll_remainder -= @floatFromInt(lines);
    for (0..@abs(lines)) |_| {
        try command(model, app, if (lines < 0) .move_up else .move_down);
    }

    return true;
}

fn scrollHistory(model: *WindowModel, app: *client.Client, event: event_module.Input) !bool {
    const prompt = app.model.name_prompt.currentConst() orelse return true;
    const state = &model.widgets;
    const history = &app.model.history_palette;
    if (history.phase != .ready) {
        state.history_scroll_remainder = 0;
        return true;
    }

    const bounds = model.overlays.presented().native_modal orelse return true;
    const pointer = if (event == .scroll) [2]f64{ event.scroll.x, event.scroll.y } else [2]f64{ event.pointer.x, event.pointer.y };
    if (!Bands.within(bounds, pointer[0], pointer[1])) {
        return true;
    }

    var delivered = false;
    var line_height: f64 = @floatFromInt(@max(1, model.pointer.geometry.size.cell_height_px));
    var row_height: ?f64 = null;
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

            // The selected row is a taller card; one step is a closed row.
            if (!prompt.inspecting()) {
                row_height = @min(row_height orelse target.bounds.height, target.bounds.height);
            }
        }
    }

    if (row_height) |height| {
        line_height = @max(1, height);
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
        try client.history_palette.scrollHistoryInspection(app, lines);
    } else {
        for (0..@abs(lines)) |_| {
            if (history.phase != .ready) {
                break;
            }

            try command(model, app, if (lines < 0) .move_up else .move_down);
        }
    }

    return true;
}
