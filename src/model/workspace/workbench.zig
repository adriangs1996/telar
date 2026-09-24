//! The grid the panes of the active tab share: what the host leaves after
//! its chrome.
const cellgrid = @import("cellgrid");
const std = @import("std");
const ClientModel = @import("../state/ClientModel.zig");
const GridRegions = @import("../layout/GridRegions.zig");
const Region = @import("Region.zig");

/// Derives the workbench from the host size and the sidebar layout. The
/// revision advances whenever either input changes.
/// Example: `const area = workbench.region(&model).area;`
pub fn region(model: *const ClientModel) Region {
    const size = model.host.host_size;
    const area: cellgrid.Rect = if (model.host.grid_chrome)
        GridRegions.calculate(size.cols, size.rows, model.sidebar_visible, model.sidebar_width).workbench
    else
        .{
            .w = size.cols,
            .h = size.rows,
        };

    return .{
        .area = area,
        .revision = model.host.host_revision +% model.chrome_revision +% 1,
    };
}

test "a window's workbench is its whole grid and a terminal's is what its chrome leaves" {
    var model = ClientModel.initWithState(std.testing.allocator, .{
        .pane_gaps = true,
        .host_size = .{ .cols = 120, .rows = 40 },
    });
    defer model.deinit();

    try std.testing.expectEqual(cellgrid.Rect{ .w = 120, .h = 40 }, region(&model).area);

    model.host.grid_chrome = true;
    try std.testing.expectEqual(cellgrid.Rect{ .x = 42, .y = 1, .w = 78, .h = 38 }, region(&model).area);
}

test "a workbench that returns to its old area still invalidates captured input" {
    var model = ClientModel.initWithState(std.testing.allocator, .{
        .pane_gaps = true,
        .host_size = .{ .cols = 80, .rows = 24 },
    });
    defer model.deinit();
    const captured = region(&model);

    try std.testing.expect(captured.matches(region(&model)));
    model.host.host_size.cols = 10;
    model.host.host_revision +%= 1;
    try std.testing.expect(!captured.matches(region(&model)));
    model.host.host_size.cols = 80;
    model.host.host_revision +%= 1;
    try std.testing.expect(!captured.matches(region(&model)));
}
