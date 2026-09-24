//! Adopting a configuration generation into the client model.

const ConfigurationInput = @import("../state/ConfigurationInput.zig");
const std = @import("std");
const tab_layout = @import("../workspace/tab_layout.zig");
const model_data = @import("../model.zig");
const sidebar = @import("../layout/sidebar.zig");
const ClientModel = @import("../state/ClientModel.zig");

/// Atomically adopts one newer configuration's semantic client settings.
///
/// ```zig
/// const commit = try config_reload.apply(model, input);
/// ```
pub fn apply(model: *ClientModel, input: ConfigurationInput) !model_data.ConfigurationCommit {
    if (input.generation <= model.configuration_generation) {
        return error.StaleConfiguration;
    }

    const sidebar_change = sidebar.setVisible(model, input.sidebar_visible);
    const pane_gaps_changed = model.pane_gaps != input.pane_gaps;
    if (pane_gaps_changed) {
        tab_layout.setPaneGaps(model, input.pane_gaps);
        model.panes_revision +%= 1;
    }

    const bars_changed = model.bars.replace(input.bars) == .changed;
    if (bars_changed) {
        model.bars_revision +%= 1;
    }

    std.debug.assert(input.window_title.len <= model.window_title_template.len);
    @memcpy(model.window_title_template[0..input.window_title.len], input.window_title);
    model.window_title_template_len = @intCast(input.window_title.len);

    model.config = input.config;
    model.configuration_generation = input.generation;
    model.configuration_revision +%= 1;

    return .{
        .generation = model.configuration_generation,
        .configuration_revision = model.configuration_revision,
        .sidebar = sidebar_change,
        .pane_gaps_changed = pane_gaps_changed,
        .panes_revision = model.panes_revision,
        .bars_changed = bars_changed,
        .bars_revision = model.bars_revision,
    };
}

/// Returns the configured host window title template; empty disables it.
///
/// ```zig
/// const template = config_reload.windowTitleTemplate(model);
/// ```
pub fn windowTitleTemplate(model: *const ClientModel) []const u8 {
    return model.window_title_template[0..model.window_title_template_len];
}
