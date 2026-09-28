//! Composition selects the concrete modal before any widget emits quads.
const cellgrid = @import("cellgrid");
const HistoryModalMetrics = @import("HistoryModalMetrics.zig");
const WorkspaceFormLayout = @import("WorkspaceFormLayout.zig");
const HistoryModalLayout = @import("HistoryModalLayout.zig");
const Canvas = @import("../Canvas.zig");
const Modal = @import("Modal.zig");
const NamePrompt = @import("NamePrompt.zig");
const WorkspaceForm = @import("WorkspaceForm.zig");
const PickerModal = @import("PickerModal.zig");
const HistoryModal = @import("HistoryModal.zig");
const SuggestionModal = @import("SuggestionModal.zig");
const PeekModal = @import("PeekModal.zig");
const CommandPalette = @import("CommandPalette.zig");
const PathPicker = @import("PathPicker.zig");
const OverlayComposition = @import("OverlayComposition.zig");
const HitState = @import("HitState.zig");

pub const Widget = union(enum) {
    name_prompt: NamePrompt,
    workspace_form: WorkspaceForm,
    picker: PickerModal,
    history: HistoryModal,
    suggestion: SuggestionModal,
    peek: PeekModal,
    palette: CommandPalette,
    paths: PathPicker,

    /// Example: `try modal.draw(canvas);`
    pub fn draw(self: Widget, canvas: *Canvas) !void {
        switch (self) {
            inline else => |value| try value.draw(canvas),
        }
    }
};

/// Resolves the prompt kind before drawing, borrowing the caller's projection
/// until the list finishes. Example: `try modal_widget.compose(input, pending, widgets);`
pub fn compose(input: OverlayComposition, pending: *HitState, widgets: anytype) !void {
    const prompt = if (input.projection.prompt) |*value| value else return;
    if (prompt.target() == .palette) {
        try widgets.append(.{ .modal = .{ .palette = .{ .projection = input.projection, .hits = &pending.palette, .modal = &pending.modal, .router = input.router, .scale = input.scale } } });
        return;
    }

    if (prompt.target() == .paths) {
        try widgets.append(.{ .modal = .{ .paths = .{
            .projection = input.projection,
            .hits = &pending.palette,
            .modal = &pending.modal,
            .scale = input.scale,
        } } });
        return;
    }

    const host: cellgrid.Rect = .{ .w = input.projection.host_size.cols, .h = input.projection.host_size.rows };
    if (prompt.target() == .create_workspace) {
        const layout = try WorkspaceFormLayout.measure(input.canvas, input.projection);
        pending.modal = host;
        pending.native_modal = layout.bounds;
        try widgets.append(.{ .modal = .{ .workspace_form = .{ .layout = layout, .projection = input.projection } } });
        return;
    }

    if (prompt.target() == .history) {
        const metrics = HistoryModalMetrics.fromCanvas(input.canvas);
        var layout = HistoryModalLayout.measure(metrics, prompt.inspecting());
        const offset = @min(input.canvas.chrome.px(12), @max(0, layout.viewport.height - layout.bounds.y - layout.bounds.height));
        layout.offsetY(offset * (1 - input.history_reveal));
        pending.modal = host;
        pending.native_modal = layout.bounds;
        try widgets.append(.{
            .modal = .{
                .history = .{
                    .layout = layout,
                    .projection = input.projection,
                    .reveal = input.history_reveal,
                    .loading = input.history_loading,
                },
            },
        });
        return;
    }

    const area = switch (prompt.target()) {
        .goto => Modal.bounds(host, .{ .w = 84, .h = 18 }),
        .suggest => Modal.bounds(host, .{ .w = 84, .h = 9 }),
        .peek => Modal.bounds(host, .{ .w = 96, .h = 24 }),
        else => Modal.bounds(host, .{ .w = 64, .h = 7 }),
    };
    pending.modal = area;
    const widget: Widget = switch (prompt.target()) {
        .goto => .{ .picker = .{ .area = area, .projection = input.projection } },
        .suggest => .{ .suggestion = .{ .area = area, .projection = input.projection } },
        .peek => .{ .peek = .{ .area = area, .projection = input.projection } },
        .rename_tab => .{ .name_prompt = .{ .area = area, .prompt = prompt, .title = "Rename tab" } },
        .rename_workspace => .{ .name_prompt = .{ .area = area, .prompt = prompt, .title = "Rename workspace" } },
        .copy_search => |direction| .{ .name_prompt = .{ .area = area, .prompt = prompt, .title = if (direction == .forward) "Search forward" else "Search backward" } },
        .palette, .create_workspace, .history, .paths => unreachable,
    };
    try widgets.append(.{ .modal = widget });
}
