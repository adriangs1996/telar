//! List viewports travel with the delivered hit map, never the pending frame.
const Rect = @import("../render/Rect.zig");
const Bands = @import("Bands.zig");
const Canvas = @import("Canvas.zig");
const Layout = @import("../layout/Layout.zig");
const LayoutItem = @import("../layout/Item.zig");
const WorkspaceRow = @import("WorkspaceRow.zig");
const SidebarRegions = @This();

pub const margin: f32 = 8;
pub const header_gap: f32 = 6;
pub const List = enum { projects, agents };
projects_header: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
agents_header: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
projects: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
agents: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

/// Caps projects at 40% of the inset band; short windows use top-bar navigation.
/// Example: `const regions = try SidebarRegions.resolve(canvas, band, workspace_count);`
pub fn resolve(canvas: *const Canvas, area: Rect, count: usize) !SidebarRegions {
    const inset = canvas.chrome.px(margin);
    const content: Rect = .{ .x = area.x + inset, .y = area.y + inset, .width = @max(0, area.width - 1 - 2 * inset), .height = @max(0, area.height - 2 * inset) };
    const header = canvas.chrome.rowHeight(.body);
    const gap = canvas.chrome.px(header_gap);
    if (content.width <= 0 or content.height < header) {
        return .{};
    }

    const total = if (count == 0) header else @as(f32, @floatFromInt(count)) * WorkspaceRow.height(canvas);
    const project_height = @min(total, @max(0, @floor(content.height * 0.4) - header - gap));
    if (project_height < header) {
        return .{
            .agents_header = .{ .x = content.x, .y = content.y, .width = content.width, .height = header },
            .agents = .{ .x = content.x, .y = content.y + header + gap, .width = content.width, .height = @max(0, content.height - header - gap) },
        };
    }

    var rows = [_]LayoutItem{
        .{ .height = .{ .fixed = header } },
        .{ .height = .{ .fixed = project_height } },
        .{ .height = .{ .fixed = header } },
        .{},
    };
    try (Layout{ .area = content, .direction = .column, .gap = gap }).resolve(&rows);
    return .{ .projects_header = rows[0].bounds, .projects = rows[1].bounds, .agents_header = rows[2].bounds, .agents = rows[3].bounds };
}

/// Headers and the resize gutter do not scroll either list.
/// Example: `const list = regions.at(.{ pointer.x, pointer.y }) orelse return;`
pub fn at(regions: SidebarRegions, point: [2]f64) ?List {
    if (Bands.within(regions.projects, point[0], point[1])) {
        return .projects;
    }

    if (Bands.within(regions.agents, point[0], point[1])) {
        return .agents;
    }

    return null;
}
