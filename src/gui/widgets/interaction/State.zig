//! Presentation-owned targets plus client-owned transient editor state.
const std = @import("std");
const client = @import("telar-client");
const Canvas = @import("../../chrome/Canvas.zig");
const GenericPresentedState = @import("../../render/GenericPresentedState.zig").Type;
const Dispatcher = @import("Dispatcher.zig");
const Editors = @import("Editors.zig");
const Preedit = @import("Preedit.zig");
const Target = @import("Target.zig");
const Id = @import("Id.zig");
const State = @This();

dispatcher: Dispatcher = .{},
editors: GenericPresentedState(Editors) = .{},
preedit: Preedit = .{},
prompt_generation: u64 = 0,
paste_owner: ?Id = null,
paste_consumed: bool = false,
paste_buffer: @import("PasteBuffer.zig") = .{},
paste_selection: [2]u32 = .{ 0, 0 },
paste_revision: u64 = 0,
sidebar_scroll_remainder: f64 = 0,
native_nodes: [@import("Registry.zig").capacity]@import("../../native/native.zig").AccessibilityNode = undefined,
pending_cuts: [4]?@import("PendingCut.zig") = @splat(null),

/// Cancelling provisional text changes pixels even when committed text and
/// selection stay untouched. Example: `state.cancelComposition();`
pub fn cancelComposition(state: *State) void {
    if (state.preedit.owner != null) {
        state.preedit.clear();
        state.dispatcher.revision +%= 1;
    }
}

/// Example: `state.begin(projection.prompt != null);`
pub fn begin(state: *State, modal: bool) void {
    state.dispatcher.begin().modal_layer = if (modal) 1 else 0;
    _ = state.editors.begin();
}

/// Imports existing chrome's semantic controls with their exact rectangles.
/// Example: `try state.chrome(canvas, &chrome);`
pub fn chrome(state: *State, canvas: *Canvas, input: @import("ChromeRegistration.zig")) !void {
    const value = input.chrome;
    if (value.prepared().bands.sidebar.width > 0) {
        _ = try state.dispatcher.add((Target{ .bounds = value.prepared().bands.sidebar, .action = .{ .custom = 1 }, .namespace = 1, .focusable = false, .role = 6 }).labelled("Agents"));
    }

    for (value.prepared().band_hits.items[0..value.prepared().band_hits.len]) |hit| {
        const action: Target.Action = switch (hit.action) {
            .intent => |intent| if (intent == .none) continue else .{ .intent = intent },
            .resize_sidebar => .resize_sidebar,
            .pane_content => continue,
        };
        const target: Target = .{ .bounds = hit.area, .action = action, .focusable = action != .resize_sidebar };
        _ = try state.dispatcher.add(target.labelled(@import("labels.zig").forAction(input.projection, action)));
    }

    if (state.dispatcher.focused) |id| {
        if (state.dispatcher.maps.prepared().find(id)) |target| {
            if (target.action != .text_field and state.dispatcher.maps.prepared().modal_layer == 0) {
                try canvas.ringAt(target.bounds, .{ .color = canvas.theme.palette.accent, .width = 1, .radius = 4 });
            }
        }
    }
}

/// Imports modal result rows after their field, preserving painter priority.
/// Example: `try state.overlays(canvas, &overlays);`
pub fn overlays(state: *State, canvas: *Canvas, value: *@import("../../overlays/Overlays.zig")) !void {
    const palette = &value.prepared().palette;
    for (palette.rows[0..palette.count], 0..) |row, index| {
        _ = try state.dispatcher.add(.{ .id = .{ .generation = state.prompt_generation }, .bounds = canvas.rect(row), .action = .{ .intent = .{ .prompt_row = palette.first + @as(u16, @intCast(index)) } }, .layer = 1, .focusable = false });
    }
}

/// Example: `state.seal();`
pub fn seal(state: *State) void {
    state.dispatcher.seal();
    state.editors.seal();
}

/// Example: `state.present(delivered);`
pub fn present(state: *State, delivered: bool) void {
    state.dispatcher.present(delivered);
    state.editors.present(delivered);
    if (!delivered) {
        return;
    }

    for (state.editors.presented().items[0..state.editors.presented().len]) |editor| {
        if (editor.preferred) {
            _ = state.dispatcher.focus(editor.id);
            break;
        }
    }

    if (state.preedit.owner) |owner| {
        if (state.dispatcher.focused == null or !state.dispatcher.focused.?.eql(owner)) {
            state.preedit.clear();
        }
    }
}
