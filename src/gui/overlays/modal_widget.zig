//! Composition selects the concrete modal before any widget emits quads.
const Canvas = @import("../chrome/Canvas.zig");
const core = @import("telar-core");
const Modal = @import("Modal.zig");

pub const Widget = union(enum) {
    name_prompt: @import("NamePrompt.zig"),
    workspace_form: @import("WorkspaceForm.zig"),
    picker: @import("PickerModal.zig"),
    history: @import("HistoryModal.zig"),
    suggestion: @import("SuggestionModal.zig"),
    palette: @import("CommandPalette.zig"),

    /// Example: `try modal.draw(canvas);`
    pub fn draw(widget: Widget, canvas: *Canvas) !void {
        switch (widget) {
            inline else => |value| try value.draw(canvas),
        }
    }
};

/// Resolves the prompt kind before drawing, borrowing the caller's projection
/// until the list finishes. Example: `try modal_widget.compose(input, pending, widgets);`
pub fn compose(input: @import("OverlayComposition.zig"), pending: *@import("HitState.zig"), widgets: anytype) !void {
    const prompt = if (input.projection.prompt) |*value| value else return;
    if (prompt.target() == .palette) {
        try widgets.append(.{ .modal = .{ .palette = .{ .projection = input.projection, .hits = &pending.palette, .modal = &pending.modal, .router = input.router, .scale = input.scale } } });
        return;
    }

    const host: core.Rect = .{ .w = input.projection.host_size.cols, .h = input.projection.host_size.rows };
    const area = switch (prompt.target()) {
        .history => @import("HistoryModal.zig").preferredArea(input.projection.*),
        .goto => Modal.bounds(host, .{ .w = 84, .h = 18 }),
        .suggest => Modal.bounds(host, .{ .w = 84, .h = 9 }),
        .create_workspace => Modal.bounds(host, .{ .w = 72, .h = 16 }),
        else => Modal.bounds(host, .{ .w = 64, .h = 7 }),
    };
    pending.modal = area;
    const widget: Widget = switch (prompt.target()) {
        .goto => .{ .picker = .{ .area = area, .projection = input.projection } },
        .history => .{ .history = .{ .area = area, .projection = input.projection } },
        .suggest => .{ .suggestion = .{ .area = area, .projection = input.projection } },
        .create_workspace => .{ .workspace_form = .{ .area = area, .projection = input.projection } },
        .rename_tab => .{ .name_prompt = .{ .area = area, .prompt = prompt, .title = "Rename tab" } },
        .rename_workspace => .{ .name_prompt = .{ .area = area, .prompt = prompt, .title = "Rename workspace" } },
        .copy_search => |direction| .{ .name_prompt = .{ .area = area, .prompt = prompt, .title = if (direction == .forward) "Search forward" else "Search backward" } },
        .palette => unreachable,
    };
    try widgets.append(.{ .modal = widget });
}
