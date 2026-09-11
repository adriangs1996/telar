const ModelType = @import("../../model/Model.zig");
const HostResourceDeliveryEffects = @import("HostResourceDeliveryEffects.zig");
const HostCommitType = @import("../../model/HostCommit.zig");
const std = @import("std");
const DeliverHostResourcesHandler = @This();

model: *const ModelType,
effects: HostResourceDeliveryEffects,

/// Delivers the resources implied by one current `HostCommit` in graphics,
/// presentation and pane-geometry order.
///
/// ```zig
/// try handler.execute(commit);
/// ```
pub fn execute(handler: *DeliverHostResourcesHandler, commit: HostCommitType) !void {
    try handler.validate(commit);

    if (commit.capabilities) |capabilities| {
        if (!std.meta.eql(capabilities.previous.terminal_colors, capabilities.current.terminal_colors)) {
            try handler.effects.sync_terminal_colors(handler.effects.context, capabilities.current.terminal_colors);
        }

        if (capabilities.previous.appearance != capabilities.current.appearance) {
            try handler.effects.apply_appearance(handler.effects.context, capabilities.current.appearance);
        }

        const graphics_changed = capabilities.previous.images !=
            capabilities.current.images;
        if (graphics_changed) {
            handler.effects.sync_graphics_fallbacks(handler.effects.context);
            try handler.effects.configure_sidebar(handler.effects.context, .{
                .capabilities = capabilities.current,
                .size = handler.model.hostSize(),
            });
            handler.effects.invalidate_graphics_placements(handler.effects.context);
        }
    }

    if (commit.resize) |resize| {
        if (resize.grid_changed) {
            try handler.effects.resize_presenter(handler.effects.context, resize.current);
            try handler.effects.resize_view(handler.effects.context, resize.current);
        }

        if (resize.cell_size_changed) {
            try handler.effects.configure_sidebar(handler.effects.context, .{
                .capabilities = handler.model.hostCapabilities(),
                .size = resize.current,
            });
        }

        handler.effects.invalidate_graphics_placements(handler.effects.context);
        try handler.effects.sync_pane_geometry(handler.effects.context);
    }
}

fn validate(handler: *const DeliverHostResourcesHandler, commit: HostCommitType) !void {
    if (commit.capabilities == null and commit.resize == null) {
        return error.EmptyHostCommit;
    }

    const version = handler.model.version();
    if (commit.capabilities) |capabilities| {
        if (!std.meta.eql(handler.model.hostCapabilities(), capabilities.current) or
            version.host_capabilities != capabilities.host_capabilities_revision)
        {
            return error.StaleHostCommit;
        }
    }

    if (commit.resize) |resize| {
        if (!std.meta.eql(handler.model.hostSize(), resize.current) or
            version.host != resize.host_revision)
        {
            return error.StaleHostCommit;
        }
    }
}
