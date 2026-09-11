//! Application policy for delivering one atomically committed workspace
//! creation replacement.

const PaneIdType = @import("telar-core").PaneId;
const ModelType = @import("../../model/Model.zig");
const WorkspaceCreationDeliveryEffectsCapture = @import("WorkspaceCreationDeliveryEffectsCapture.zig");
const DeliverWorkspaceCreationHandler = @import("DeliverWorkspaceCreationHandler.zig");
const WorkspaceCreationDeliveryTestingModel = @import("WorkspaceCreationDeliveryTestingModel.zig");
const std = @import("std");

pub fn containsPane(panes: []const PaneIdType, wanted: PaneIdType) bool {
    for (panes) |pane_id| {
        if (pane_id == wanted) {
            return true;
        }
    }

    return false;
}

pub const Event = enum {
    remember_bookmark,
    clear_pane_graphics,
    synchronize_active_resources,
    schedule_host_input,
    request_workspace_snapshot,
    request_tab_snapshot,
};

pub const Failure = enum {
    none,
    active_resources,
};

fn deliveryHandler(model: *ModelType, capture: *WorkspaceCreationDeliveryEffectsCapture) DeliverWorkspaceCreationHandler {
    return .{
        .model = model,
        .release_effects = capture.releaseEffects(),
        .activation_effects = capture.activationEffects(),
    };
}

test "DeliverWorkspaceCreationHandler releases before ordered activation" {
    var testing = try WorkspaceCreationDeliveryTestingModel.init();
    defer testing.deinit();
    const replacement = try testing.replace();
    var capture: WorkspaceCreationDeliveryEffectsCapture = .{
        .model = testing.model,
        .replacement = &replacement,
    };
    var handler = deliveryHandler(testing.model, &capture);

    try handler.execute(&replacement);

    try std.testing.expectEqualSlices(Event, &.{
        .remember_bookmark,
        .clear_pane_graphics,
        .clear_pane_graphics,
        .synchronize_active_resources,
        .schedule_host_input,
        .request_workspace_snapshot,
        .request_tab_snapshot,
    }, capture.eventSlice());
    try std.testing.expectEqualDeep(replacement.departure.bookmark.?, capture.remembered.?);
    try std.testing.expectEqualSlices(PaneIdType, replacement.departure.panes.slice(), capture.cleared_panes[0..capture.cleared_count]);
    try std.testing.expectEqualDeep(replacement.activation.location.workspace, capture.workspace_request.?);
    try std.testing.expectEqualDeep(replacement.activation.location, capture.tab_request.?);
    try std.testing.expect(capture.release_complete_before_activation);
    try std.testing.expect(capture.exact_commit_observed);
}

test "DeliverWorkspaceCreationHandler accepts an exact invalid-copy release" {
    var testing = try WorkspaceCreationDeliveryTestingModel.init();
    defer testing.deinit();
    const paste = testing.model.panePasteSession().?;
    try std.testing.expect(testing.model.finishPanePaste(paste));
    try std.testing.expect(testing.model.enterCopyMode());
    const replacement = try testing.replace();
    var capture: WorkspaceCreationDeliveryEffectsCapture = .{
        .model = testing.model,
        .replacement = &replacement,
    };
    var handler = deliveryHandler(testing.model, &capture);

    try handler.execute(&replacement);

    try std.testing.expect(replacement.activation.copy_released);
    try std.testing.expectEqual(replacement.activation.copy_revision_before +% 1, replacement.activation.copy_revision);
    try std.testing.expect(!testing.model.copyModeActive());
    try std.testing.expect(capture.release_complete_before_activation);
    try std.testing.expect(capture.exact_commit_observed);
}

test "DeliverWorkspaceCreationHandler validates replacement before release" {
    var testing = try WorkspaceCreationDeliveryTestingModel.init();
    defer testing.deinit();
    const replacement = try testing.replace();
    var capture: WorkspaceCreationDeliveryEffectsCapture = .{
        .model = testing.model,
        .replacement = &replacement,
    };
    var handler = deliveryHandler(testing.model, &capture);

    var altered = replacement;
    altered.activation.workspace_revision -%= 1;
    try std.testing.expectError(error.StaleWorkspaceActivation, handler.execute(&altered));
    altered = replacement;
    altered.activation.workspace_revision_before -%= 1;
    try std.testing.expectError(error.StaleWorkspaceActivation, handler.execute(&altered));
    altered = replacement;
    altered.activation.tabs_revision_before -%= 1;
    try std.testing.expectError(error.StaleWorkspaceActivation, handler.execute(&altered));
    altered = replacement;
    altered.activation.active_tab_revision_before -%= 1;
    try std.testing.expectError(error.StaleWorkspaceActivation, handler.execute(&altered));
    altered = replacement;
    altered.activation.panes_revision_before -%= 1;
    try std.testing.expectError(error.StaleWorkspaceActivation, handler.execute(&altered));
    altered = replacement;
    altered.activation.copy_revision_before -%= 1;
    try std.testing.expectError(error.StaleWorkspaceActivation, handler.execute(&altered));
    altered = replacement;
    altered.activation.copy_revision -%= 1;
    try std.testing.expectError(error.StaleWorkspaceActivation, handler.execute(&altered));
    altered = replacement;
    altered.activation.copy_released = !altered.activation.copy_released;
    try std.testing.expectError(error.StaleWorkspaceActivation, handler.execute(&altered));
    altered = replacement;
    altered.departure.source = replacement.activation.location.workspace;
    try std.testing.expectError(error.StaleWorkspaceCreation, handler.execute(&altered));
    altered = replacement;
    altered.departure.panes.items[1] = altered.departure.panes.items[0];
    try std.testing.expectError(error.StaleWorkspaceCreation, handler.execute(&altered));
    altered = replacement;
    altered.departure.panes.items[0] = replacement.activation.pane_id;
    try std.testing.expectError(error.StaleWorkspaceCreation, handler.execute(&altered));
    altered = replacement;
    altered.departure.bookmark.?.location.workspace = replacement.activation.location.workspace;
    try std.testing.expectError(error.StaleWorkspaceCreation, handler.execute(&altered));
    try testing.model.workspace.active().?.model.split(.{ .existing_pane = testing.created_root, .new_pane = @enumFromInt(4), .location = testing.created, .axis = .vertical, .area = .{ .w = 50, .h = 12 } });
    try std.testing.expectError(error.StaleWorkspaceActivation, handler.execute(&replacement));

    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
}

test "DeliverWorkspaceCreationHandler preserves release after activation failure" {
    var testing = try WorkspaceCreationDeliveryTestingModel.init();
    defer testing.deinit();
    const replacement = try testing.replace();
    var capture: WorkspaceCreationDeliveryEffectsCapture = .{
        .model = testing.model,
        .replacement = &replacement,
        .failure = .active_resources,
    };
    var handler = deliveryHandler(testing.model, &capture);

    try std.testing.expectError(error.ActiveResourcesFailed, handler.execute(&replacement));

    try std.testing.expectEqual(
        Event.synchronize_active_resources,
        capture.eventSlice()[capture.event_count - 1],
    );
    try std.testing.expectEqual(replacement.departure.panes.slice().len, capture.cleared_count);
    try std.testing.expect(capture.release_complete_before_activation);
    try std.testing.expect(capture.exact_commit_observed);
    try std.testing.expectEqualDeep(replacement.activation.location, testing.model.activeTabLocation().?);
}

test "DeliverWorkspaceCreationHandler activates an exact replacement from an empty source" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    const replacement = try model.replaceWorkspace(.{
        .pane_id = @enumFromInt(3),
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(2) },
            .tab_id = @enumFromInt(2),
        },
        .size = .{ .cols = 50, .rows = 12 },
    });
    var capture: WorkspaceCreationDeliveryEffectsCapture = .{
        .model = &model,
        .replacement = &replacement,
    };
    var handler = deliveryHandler(&model, &capture);

    try handler.execute(&replacement);

    try std.testing.expectEqualSlices(Event, &.{
        .synchronize_active_resources,
        .schedule_host_input,
        .request_workspace_snapshot,
        .request_tab_snapshot,
    }, capture.eventSlice());
    try std.testing.expect(capture.release_complete_before_activation);
    try std.testing.expect(capture.exact_commit_observed);
}
