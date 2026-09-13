const client = @import("telar-client");
const Modal = @import("Modal.zig");

/// Draws name editing and copy search using the same bounded prompt state.
/// Example: `try paint(modal, prompt);`.
pub fn paint(modal: Modal, prompt: client.Prompt) !void {
    const title: []const u8 = switch (prompt.target()) {
        .rename_tab => "Rename tab",
        .create_workspace => "Create workspace",
        .rename_workspace => "Rename workspace",
        .copy_search => |direction| if (direction == .forward) "Search forward" else "Search backward",
        else => unreachable,
    };
    try modal.frame(title);

    const content = modal.content();
    try modal.field(content.row(if (content.h > 2) 1 else 0), prompt);

    if (content.h > 2) {
        try modal.line(content.h - 1, .{ .text = "Enter confirm  Esc cancel", .color = modal.canvas.theme.palette.subtext0 });
    }
}
