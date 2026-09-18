//! A disposable preview owns its path and the exact draft control that opened it.
const std = @import("std");
const core = @import("telar-core");
const Rect = @import("../../render/Rect.zig");
const Preview = @This();

control: @import("AgentControl.zig"),
generation: u64,
path_storage: [core.AgentImages.max_path_bytes]u8 = undefined,
path_len: u16,

/// Example: `const path = preview.path();`
pub fn path(preview: *const Preview) []const u8 {
    return preview.path_storage[0..preview.path_len];
}

/// Original pixels do not depend on draft text, image order, theme or DPI.
/// Example: `const request = ImagePreview.requestFor(source);`
pub fn requestFor(source: @import("ImagePreviewSource.zig")) @import("../../diagrams/Request.zig") {
    return .{
        .kind = .local_image,
        .owner = .{ .pane_id = source.pane_id, .attachment_generation = source.generation, .pane_generation = 0, .snapshot_revision = 0, .item_identity = 0, .section = .body, .source_offset = 0 },
        .block_offset = 0,
        .text = source.path,
        .theme = .{ .bg = .{ 0, 0, 0 }, .fg = .{ 0, 0, 0 }, .accent = .{ 0, 0, 0 } },
        .scale = 1,
    };
}

/// Fits the complete image without stretching or cropping, including tiny panes.
/// Example: `const bounds = ImagePreview.fit(viewport, .{ width, height });`
pub fn fit(area: Rect, size: [2]u32) Rect {
    const width: f32 = @floatFromInt(@max(1, size[0]));
    const height: f32 = @floatFromInt(@max(1, size[1]));
    const scale = @min(area.width / width, area.height / height);
    const w = width * scale;
    const h = height * scale;
    return .{ .x = area.x + (area.width - w) / 2, .y = area.y + (area.height - h) / 2, .width = w, .height = h };
}

/// Example: `if (preview.matches(target)) keepOpen();`
pub fn matches(preview: Preview, target: @import("Target.zig")) bool {
    return target.id.generation == preview.generation and target.action == .agent_control and std.meta.eql(target.action.agent_control, preview.control);
}
