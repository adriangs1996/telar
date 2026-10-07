//! The grid the panes of the active tab share: what the host leaves after
//! its chrome.
const cellgrid = @import("cellgrid");
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
