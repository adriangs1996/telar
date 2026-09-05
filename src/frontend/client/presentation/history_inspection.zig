//! Projects the history inspector's geometry without mutating semantic state.

const model = @import("../model/root.zig");
const widget = @import("../../widgets/root.zig").history_browser;

/// Returns the current inspector's scroll bound, when clamping is needed.
/// Example: `const limit = scrollLimit(&client.model) orelse return;`.
pub fn scrollLimit(state: *const model.Model) ?u32 {
    const prompt = state.name_prompt.currentConst() orelse return null;
    const palette = &state.history_palette;
    if (prompt.target != .history or !prompt.inspecting or prompt.detail_scroll == 0 or
        palette.phase != .ready or palette.len == 0)
    {
        return null;
    }

    const selection = @min(prompt.selection, palette.len - 1);
    const entry = &palette.slice()[selection];
    const size = state.hostSize();
    return widget.inspectionScrollLimit(.{ .w = size.cols, .h = size.rows }, .{
        .entry = .{
            .id = entry.id,
            .command = palette.commandAt(selection) orelse entry.commandSlice(),
            .cwd = entry.cwdSlice(),
            .pane_id = entry.pane_id,
            .started_at_ms = entry.started_at_ms,
            .duration_ns = entry.duration_ns,
            .exit_code = entry.exit_code,
            .status = entry.status,
            .author = entry.author,
        },
        .output = palette.outputSlice(),
        .output_hint = palette.outputHint(),
    });
}
