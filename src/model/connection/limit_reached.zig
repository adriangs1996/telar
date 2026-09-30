//! Limit reached, the model's side (docs/flows/limit-reached.md): a pane
//! whose graphics paused at a limit keeps its pause row only while the
//! client mirrors it, so no row outlives its pane and the table never fills
//! with panes that are gone.
const std = @import("std");
const core = @import("telar-core");
const ClientModel = @import("../state/ClientModel.zig");
const workspace_handoff = @import("../workspace/workspace_handoff.zig");
const tab_layout = @import("../workspace/tab_layout.zig");
const tab_removal = @import("../workspace/tab_removal.zig");

/// Removes the pause rows of panes that left the model. Every flow that
/// removes panes calls it once after removing them; it walks the pause
/// rows only, so it costs one comparison while no pane is paused.
///
/// ```zig
/// model.panes.removeTab(tab_id);
/// limit_reached.forgetClosedPanes(model);
/// ```
pub fn forgetClosedPanes(model: *ClientModel) void {
    const pauses = &model.graphics_pauses;
    var slot = pauses.count;
    while (slot > 0) {
        slot -= 1;
        if (model.panes.findConst(pauses.pane_id[slot]) == null) {
            pauses.remove(slot);
        }
    }
}

test "a closed pane, a removed tab and a new workspace drop their pause rows" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();

    const location: core.TabLocation = .{
        .workspace = .{
            .workspace = @enumFromInt(1),
        },
        .tab_id = @enumFromInt(2),
    };
    try workspace_handoff.bootstrap(
        &model,
        .{
            .pane_id = @enumFromInt(3),
            .location = location,
            .size = .{
                .cols = 80,
                .rows = 24,
            },
        },
    );
    const slot = model.graphics_pauses.add(@enumFromInt(3), 0);
    model.graphics_pauses.setWaiting(slot, true);

    try std.testing.expect(tab_layout.removePane(&model, @enumFromInt(3)));
    try std.testing.expectEqual(@as(usize, 0), model.graphics_pauses.count);
    try std.testing.expectEqual(@as(usize, 0), model.graphics_pauses.waiting_count);

    workspace_handoff.clear(&model);
    try workspace_handoff.bootstrap(
        &model,
        .{
            .pane_id = @enumFromInt(4),
            .location = location,
            .size = .{
                .cols = 80,
                .rows = 24,
            },
        },
    );
    _ = model.graphics_pauses.add(@enumFromInt(4), 0);
    try std.testing.expect(tab_removal.remove(&model, location.tab_id));
    try std.testing.expectEqual(@as(usize, 0), model.graphics_pauses.count);

    try workspace_handoff.bootstrap(
        &model,
        .{
            .pane_id = @enumFromInt(5),
            .location = location,
            .size = .{
                .cols = 80,
                .rows = 24,
            },
        },
    );
    _ = model.graphics_pauses.add(@enumFromInt(5), 0);
    workspace_handoff.clear(&model);
    try std.testing.expectEqual(@as(usize, 0), model.graphics_pauses.count);
}
