//! A workspace's mark in navigation: its landed favicon, else the folder
//! glyph in the caller's ink. The top-bar indicators and the rail draw the
//! same mark, so a workspace looks alike wherever it is picked.
const cellgrid = @import("cellgrid");
const core = @import("telar-core");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const label_size = @import("label_size.zig");
const AgentCard = @import("AgentCard.zig");
const Canvas = @import("Canvas.zig");
const Context = @import("Context.zig");
const WorkspaceMark = @This();

/// Opacity of a favicon whose workspace is neither selected nor hovered.
pub const muted_alpha: f32 = 0.6;

context: *const Context,
workspace: core.WorkspaceId,
bounds: Rect,
ink: cellgrid.Color,
emphasized: bool,
size: label_size.Size = .small,

/// Example: `try (WorkspaceMark{ .context = context, .workspace = id, .bounds = icon, .ink = ink, .emphasized = selected }).draw(canvas);`
pub fn draw(self: WorkspaceMark, canvas: *Canvas) !void {
    const sprite = if (self.context.favicons) |favicons| favicons.sprite(.{ .workspace = self.workspace }) else null;
    if (sprite) |value| {
        try canvas.spriteTintedAt(self.bounds, .{
            .sprite = value,
            .alpha = if (self.emphasized) 1 else muted_alpha,
        });
        return;
    }

    try canvas.iconAt(self.bounds, .{
        .text = AgentCard.project_glyph,
        .color = self.ink,
        .face = .sans,
        .size = self.size,
    });
}
