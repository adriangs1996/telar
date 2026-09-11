const State = @This();
const schema = @import("telar-core").schema;
const source_namespace = @import("host.zig");
const std = @import("std");
host_size: schema.TerminalSize,
host_revision: u64 = 0,
host_capabilities: source_namespace.HostCapabilities,
host_capabilities_revision: u64 = 0,

/// Example: `const result = state.hostSize(...);`.
pub fn hostSize(state: *const State) schema.TerminalSize {
    return state.host_size;
}

/// Example: `const result = state.hostCapabilities(...);`.
pub fn hostCapabilities(state: *const State) source_namespace.HostCapabilities {
    return state.host_capabilities;
}

/// Example: `const result = state.reconcileHost(...);`.
pub fn reconcileHost(state: *State, update: source_namespace.HostUpdate) !?source_namespace.HostCommit {
    try update.size.validate();
    const cell_size = update.capabilities.cellSize(update.size.cols, update.size.rows);
    if (update.size.cell_width_px != cell_size.width or
        update.size.cell_height_px != cell_size.height)
    {
        return error.InconsistentHostGeometry;
    }

    const capabilities_changed = !std.meta.eql(state.host_capabilities, update.capabilities);
    const size_changed = !std.meta.eql(state.host_size, update.size);
    if (!capabilities_changed and !size_changed) {
        return null;
    }

    const capabilities = if (capabilities_changed) changed: {
        const previous = state.host_capabilities;
        state.host_capabilities = update.capabilities;
        state.host_capabilities_revision +%= 1;

        break :changed source_namespace.HostCapabilitiesChange{
            .previous = previous,
            .current = update.capabilities,
            .host_capabilities_revision = state.host_capabilities_revision,
        };
    } else null;
    const resize = if (size_changed) state.commitHostResize(update.size) else null;

    return .{
        .capabilities = capabilities,
        .resize = resize,
    };
}

/// Example: `const result = state.observeHostCapability(...);`.
pub fn observeHostCapability(state: *State, observation: source_namespace.HostCapabilityObservation) !?source_namespace.HostCommit {
    const capabilities = state.host_capabilities.withObservation(observation);
    if (std.meta.eql(state.host_capabilities, capabilities)) {
        return null;
    }

    return state.reconcileHost(.{
        .capabilities = capabilities,
        .size = state.resolveHostSize(capabilities),
    });
}

fn resolveHostSize(state: *const State, capabilities: source_namespace.HostCapabilities) schema.TerminalSize {
    const cell_size = capabilities.cellSize(state.host_size.cols, state.host_size.rows);

    return .{
        .cols = state.host_size.cols,
        .rows = state.host_size.rows,
        .cell_width_px = cell_size.width,
        .cell_height_px = cell_size.height,
    };
}

fn commitHostResize(state: *State, size: schema.TerminalSize) source_namespace.HostResizeCommit {
    const previous = state.host_size;
    state.host_size = size;
    state.host_revision +%= 1;

    return .{
        .previous = previous,
        .current = size,
        .grid_changed = previous.cols != size.cols or previous.rows != size.rows,
        .cell_size_changed = previous.cell_width_px != size.cell_width_px or
            previous.cell_height_px != size.cell_height_px,
        .host_revision = state.host_revision,
    };
}
