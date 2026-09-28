const core = @import("telar-core");
const model_data = @import("../model.zig");
const std = @import("std");
const State = @This();

host_size: core.TerminalSize,
host_revision: u64 = 0,
host_capabilities: model_data.HostCapabilities,
host_capabilities_revision: u64 = 0,
/// The adapter can capture clipboard media for attachments.
clipboard_capture: bool = false,
/// The host draws its sidebar and bars in grid cells, so the workbench is
/// what they leave. A window draws them in pixels outside the grid.
grid_chrome: bool = false,
/// The cadence at which the model ticks visible animations. Null when the
/// host paces them with its own presentation clock.
animation_frame_ns: ?u64 = null,

/// Example: `const result = state.hostSize(...);`.
/// Example: `const result = state.hostCapabilities(...);`.
/// Example: `const result = state.reconcileHost(...);`.
pub fn reconcileHost(self: *State, update: model_data.HostUpdate) !?model_data.HostCommit {
    try update.size.validate();
    const cell_size = update.capabilities.cellSize(update.size.cols, update.size.rows);
    if (update.size.cell_width_px != cell_size.width or
        update.size.cell_height_px != cell_size.height)
    {
        return error.InconsistentHostGeometry;
    }

    const capabilities_changed = !std.meta.eql(self.host_capabilities, update.capabilities);
    const size_changed = !std.meta.eql(self.host_size, update.size);
    if (!capabilities_changed and !size_changed) {
        return null;
    }

    const capabilities = if (capabilities_changed) changed: {
        const previous = self.host_capabilities;
        self.host_capabilities = update.capabilities;
        self.host_capabilities_revision +%= 1;

        break :changed model_data.HostCapabilitiesChange{
            .previous = previous,
            .current = update.capabilities,
            .host_capabilities_revision = self.host_capabilities_revision,
        };
    } else null;
    const resize = if (size_changed) self.commitHostResize(update.size) else null;

    return .{
        .capabilities = capabilities,
        .resize = resize,
    };
}

fn commitHostResize(self: *State, size: core.TerminalSize) model_data.HostResizeCommit {
    const previous = self.host_size;
    self.host_size = size;
    self.host_revision +%= 1;

    return .{
        .previous = previous,
        .current = size,
        .grid_changed = previous.cols != size.cols or previous.rows != size.rows,
        .cell_size_changed = previous.cell_width_px != size.cell_width_px or
            previous.cell_height_px != size.cell_height_px,
        .host_revision = self.host_revision,
    };
}
