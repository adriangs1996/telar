//! Application policy for delivering disposable client resources after one
//! committed tab creation.

const std = @import("std");
const core = @import("telar-core");
const workspace_capability = @import("../../../workspace/root.zig");
const client_model = @import("../../model/root.zig");
const pane_focus_reporting = @import("../panes/pane_focus_reporting.zig");
const pane_paste = @import("../input/pane_paste.zig");
const tab_attachment_retirement = @import("tab_attachment_retirement.zig");

const schema = core.schema;
const tabs_mod = workspace_capability.tabs;

pub const Effects = struct {
    context: *anyopaque,
    synchronize_active_resources: *const fn (*anyopaque) anyerror!void,
};

pub const DeliverTabCreationHandler = struct {
    model: *client_model.Model,
    paste_effects: pane_paste.Effects,
    focus_effects: pane_focus_reporting.Effects,
    attachment_effects: tab_attachment_retirement.Effects,
    effects: Effects,

    /// Validates one exact creation before retiring the previous tab's
    /// attachments and synchronizing resources for the created root pane.
    ///
    /// ```zig
    /// try handler.execute(creation);
    /// ```
    pub fn execute(handler: *DeliverTabCreationHandler, creation: client_model.TabCreation) !void {
        try handler.validate(creation);

        var retire_previous: tab_attachment_retirement.RetireTabAttachmentsHandler = .{
            .model = handler.model,
            .paste_effects = handler.paste_effects,
            .focus_effects = handler.focus_effects,
            .effects = handler.attachment_effects,
        };
        try retire_previous.execute(creation.previous);

        try handler.effects.synchronize_active_resources(handler.effects.context);
    }

    fn validate(handler: *const DeliverTabCreationHandler, creation: client_model.TabCreation) !void {
        if (std.meta.eql(creation.previous, creation.created)) {
            return error.StaleTabCreation;
        }

        const previous = try handler.exactTab(creation.previous);
        const created = try handler.exactTab(creation.created);
        const active = handler.model.workspace.activeConst() orelse return error.StaleTabCreation;
        const root = created.model.findConst(creation.created_root_pane_id) orelse return error.StaleTabCreation;
        const version = handler.model.version();
        if (!std.meta.eql(active.location, creation.created) or
            handler.model.workspace.indexOf(creation.created.tab_id) != @as(usize, creation.created_position) or
            previous.model.layout.currentRevision() != creation.previous_layout_revision or
            created.model.layout.currentRevision() != creation.created_layout_revision or
            created.model.pane_count != 1 or
            created.model.layout.focused() != creation.created_root_pane_id or
            !std.meta.eql(root.location, creation.created) or
            !root.attached or
            !created.snapshot_loaded or
            handler.model.copyModeActive() or
            version.workspace != creation.workspace_revision or
            version.tabs != creation.tabs_revision or
            version.active_tab != creation.active_tab_revision or
            version.panes != creation.panes_revision or
            version.copy != creation.copy_revision or
            creation.tabs_revision_before +% 1 != creation.tabs_revision or
            creation.active_tab_revision_before +% 1 != creation.active_tab_revision or
            creation.copy_revision_before +% @intFromBool(creation.copy_released) != creation.copy_revision)
        {
            return error.StaleTabCreation;
        }
    }

    fn exactTab(handler: *const DeliverTabCreationHandler, location: schema.TabLocation) !*tabs_mod.Tab {
        const tab = handler.model.workspace.find(location.tab_id) orelse return error.StaleTabCreation;
        if (!std.meta.eql(tab.location, location)) {
            return error.StaleTabCreation;
        }

        return tab;
    }
};

const Event = union(enum) {
    paste_finish: schema.PaneId,
    focus_out: schema.PaneId,
    attachment_pending: schema.PaneId,
    detach: schema.PaneId,
    retire_attachment: schema.PaneId,
    hide_graphics: schema.PaneId,
    synchronize_active_resources,
};

const Failure = enum {
    none,
    paste,
    focus,
    second_detach,
    active_resources,
};

const TestingModel = struct {
    model: *client_model.Model,
    previous: schema.TabLocation,
    created: schema.TabLocation,
    previous_root: schema.PaneId,
    previous_sibling: schema.PaneId,
    created_root: schema.PaneId,

    fn init() !TestingModel {
        const model = try std.testing.allocator.create(client_model.Model);
        errdefer std.testing.allocator.destroy(model);
        model.* = client_model.Model.init(std.testing.allocator, true);
        errdefer model.deinit();

        const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
        const previous: schema.TabLocation = .{
            .workspace = workspace,
            .tab_id = @enumFromInt(1),
        };
        const created: schema.TabLocation = .{
            .workspace = workspace,
            .tab_id = @enumFromInt(2),
        };
        const previous_root: schema.PaneId = @enumFromInt(1);
        const previous_sibling: schema.PaneId = @enumFromInt(2);
        const created_root: schema.PaneId = @enumFromInt(3);
        try model.workspace.bootstrap(previous_root, previous, .{ .cols = 40, .rows = 10 });
        try model.workspace.active().?.model.split(.{ .existing_pane = previous_root, .new_pane = previous_sibling, .location = previous, .axis = .horizontal, .area = .{ .w = 40, .h = 10 } });
        if (!model.workspace.active().?.model.focusPane(previous_root)) {
            return error.PreviousFocusNotRestored;
        }

        const pane = model.workspace.findPane(previous_root).?;
        pane.input_modes.bracketed_paste = true;
        pane.input_modes.focus_events = true;
        pane.pending_frame_id = 7;
        model.workspace.findPane(previous_sibling).?.pending_frame_id = 9;
        _ = model.beginPanePaste().?;
        _ = model.syncReportedPaneFocus().?;

        return .{
            .model = model,
            .previous = previous,
            .created = created,
            .previous_root = previous_root,
            .previous_sibling = previous_sibling,
            .created_root = created_root,
        };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }

    fn create(testing: *TestingModel) !client_model.TabCreation {
        return testing.model.createTab(.{
            .created = .{
                .location = testing.created,
                .position = 1,
                .label = "created",
                .root_pane_id = testing.created_root,
            },
            .size = .{ .cols = 40, .rows = 10 },
        });
    }
};

const EffectsCapture = struct {
    model: *client_model.Model,
    creation: client_model.TabCreation,
    previous_root: schema.PaneId,
    previous_sibling: schema.PaneId,
    events: [20]Event = undefined,
    event_count: usize = 0,
    committed_creation_observed: bool = true,
    previous_retired_before_sync: bool = false,
    failure: Failure = .none,

    fn pasteEffects(capture: *EffectsCapture) pane_paste.Effects {
        return .{ .context = capture, .deliver = deliverPaste };
    }

    fn focusEffects(capture: *EffectsCapture) pane_focus_reporting.Effects {
        return .{ .context = capture, .deliver = deliverFocus };
    }

    fn attachmentEffects(capture: *EffectsCapture) tab_attachment_retirement.Effects {
        return .{
            .context = capture,
            .attachment_pending = attachmentPending,
            .detach_pane = detachPane,
            .retire_attachment = retireAttachment,
            .hide_graphics = hideGraphics,
        };
    }

    fn effects(capture: *EffectsCapture) Effects {
        return .{
            .context = capture,
            .synchronize_active_resources = synchronizeActiveResources,
        };
    }

    fn deliverPaste(context: *anyopaque, delivery: pane_paste.Delivery) !bool {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        const marker = switch (delivery) {
            .marker => |value| value,
            .content => return error.UnexpectedPasteContent,
        };
        capture.append(.{ .paste_finish = marker.session.pane_id });
        if (marker.boundary != .finish) {
            return error.UnexpectedPasteBoundary;
        }
        if (capture.failure == .paste) {
            return error.PasteFailed;
        }

        return true;
    }

    fn deliverFocus(context: *anyopaque, delivery: pane_focus_reporting.Delivery) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.append(.{ .focus_out = delivery.pane_id });
        if (delivery.direction != .focus_out) {
            return error.UnexpectedFocusDirection;
        }
        if (capture.failure == .focus) {
            return error.FocusFailed;
        }
    }

    fn attachmentPending(context: *anyopaque, pane_id: schema.PaneId) bool {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.append(.{ .attachment_pending = pane_id });

        return false;
    }

    fn detachPane(context: *anyopaque, pane_id: schema.PaneId) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.append(.{ .detach = pane_id });
        if (capture.failure == .second_detach and pane_id == capture.previous_sibling) {
            return error.DetachFailed;
        }
    }

    fn retireAttachment(context: *anyopaque, pane_id: schema.PaneId) void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.append(.{ .retire_attachment = pane_id });
    }

    fn hideGraphics(context: *anyopaque, pane_id: schema.PaneId) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.append(.{ .hide_graphics = pane_id });
    }

    fn synchronizeActiveResources(context: *anyopaque) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.append(.synchronize_active_resources);
        const root = capture.model.workspace.findPane(capture.previous_root).?;
        const sibling = capture.model.workspace.findPane(capture.previous_sibling).?;
        capture.previous_retired_before_sync = !root.attached and
            !sibling.attached and
            root.pending_frame_id == 0 and
            sibling.pending_frame_id == 0 and
            !capture.model.panePasteActive() and
            capture.model.reportedPaneFocus() == null;

        if (capture.failure == .active_resources) {
            return error.ActiveResourcesFailed;
        }
    }

    fn append(capture: *EffectsCapture, event: Event) void {
        capture.committed_creation_observed = capture.committed_creation_observed and capture.observesCreation();
        capture.events[capture.event_count] = event;
        capture.event_count += 1;
    }

    fn observesCreation(capture: *const EffectsCapture) bool {
        const version = capture.model.version();
        const active = capture.model.activeTabLocation() orelse return false;

        return std.meta.eql(active, capture.creation.created) and
            version.workspace == capture.creation.workspace_revision and
            version.tabs == capture.creation.tabs_revision and
            version.active_tab == capture.creation.active_tab_revision and
            version.panes == capture.creation.panes_revision and
            version.copy == capture.creation.copy_revision;
    }

    fn eventSlice(capture: *const EffectsCapture) []const Event {
        return capture.events[0..capture.event_count];
    }
};

fn captureFor(testing: *TestingModel, creation: client_model.TabCreation) EffectsCapture {
    return .{
        .model = testing.model,
        .creation = creation,
        .previous_root = testing.previous_root,
        .previous_sibling = testing.previous_sibling,
    };
}

fn deliveryHandler(testing: *TestingModel, capture: *EffectsCapture) DeliverTabCreationHandler {
    return .{
        .model = testing.model,
        .paste_effects = capture.pasteEffects(),
        .focus_effects = capture.focusEffects(),
        .attachment_effects = capture.attachmentEffects(),
        .effects = capture.effects(),
    };
}

test "DeliverTabCreationHandler retires previous attachments before active resources" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const creation = try testing.create();
    var capture = captureFor(&testing, creation);
    var handler = deliveryHandler(&testing, &capture);

    try handler.execute(creation);

    try std.testing.expectEqualSlices(Event, &.{
        .{ .paste_finish = testing.previous_root },
        .{ .focus_out = testing.previous_root },
        .{ .attachment_pending = testing.previous_root },
        .{ .detach = testing.previous_root },
        .{ .retire_attachment = testing.previous_root },
        .{ .hide_graphics = testing.previous_root },
        .{ .attachment_pending = testing.previous_sibling },
        .{ .detach = testing.previous_sibling },
        .{ .retire_attachment = testing.previous_sibling },
        .{ .hide_graphics = testing.previous_sibling },
        .synchronize_active_resources,
    }, capture.eventSlice());
    try std.testing.expect(capture.committed_creation_observed);
    try std.testing.expect(capture.previous_retired_before_sync);
}

test "DeliverTabCreationHandler accepts an exact invalid-copy release" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const paste = testing.model.panePasteSession().?;
    try std.testing.expect(testing.model.finishPanePaste(paste));
    try std.testing.expect(testing.model.enterCopyMode());
    const creation = try testing.create();
    var capture = captureFor(&testing, creation);
    var handler = deliveryHandler(&testing, &capture);

    try handler.execute(creation);

    try std.testing.expect(creation.copy_released);
    try std.testing.expectEqual(creation.copy_revision_before +% 1, creation.copy_revision);
    try std.testing.expect(!testing.model.copyModeActive());
    try std.testing.expect(capture.previous_retired_before_sync);
    try std.testing.expect(capture.committed_creation_observed);
}

test "DeliverTabCreationHandler rejects altered commits before effects" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const creation = try testing.create();
    var capture = captureFor(&testing, creation);
    var handler = deliveryHandler(&testing, &capture);

    var altered = creation;
    altered.workspace_revision -%= 1;
    try std.testing.expectError(error.StaleTabCreation, handler.execute(altered));
    altered = creation;
    altered.tabs_revision -%= 1;
    try std.testing.expectError(error.StaleTabCreation, handler.execute(altered));
    altered = creation;
    altered.active_tab_revision -%= 1;
    try std.testing.expectError(error.StaleTabCreation, handler.execute(altered));
    altered = creation;
    altered.panes_revision -%= 1;
    try std.testing.expectError(error.StaleTabCreation, handler.execute(altered));
    altered = creation;
    altered.copy_revision -%= 1;
    try std.testing.expectError(error.StaleTabCreation, handler.execute(altered));
    altered = creation;
    altered.copy_revision_before -%= 1;
    try std.testing.expectError(error.StaleTabCreation, handler.execute(altered));
    altered = creation;
    altered.tabs_revision_before -%= 1;
    try std.testing.expectError(error.StaleTabCreation, handler.execute(altered));
    altered = creation;
    altered.active_tab_revision_before -%= 1;
    try std.testing.expectError(error.StaleTabCreation, handler.execute(altered));
    altered = creation;
    altered.copy_released = !altered.copy_released;
    try std.testing.expectError(error.StaleTabCreation, handler.execute(altered));
    altered = creation;
    altered.previous_layout_revision -%= 1;
    try std.testing.expectError(error.StaleTabCreation, handler.execute(altered));
    altered = creation;
    altered.created_layout_revision -%= 1;
    try std.testing.expectError(error.StaleTabCreation, handler.execute(altered));
    altered = creation;
    altered.created_root_pane_id = testing.previous_root;
    try std.testing.expectError(error.StaleTabCreation, handler.execute(altered));
    altered = creation;
    altered.created_position = 0;
    try std.testing.expectError(error.StaleTabCreation, handler.execute(altered));
    altered = creation;
    altered.previous = altered.created;
    try std.testing.expectError(error.StaleTabCreation, handler.execute(altered));

    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
}

test "DeliverTabCreationHandler catches active identity and layout ABA" {
    var identity_testing = try TestingModel.init();
    defer identity_testing.deinit();
    const identity_creation = try identity_testing.create();
    var identity_capture = captureFor(&identity_testing, identity_creation);
    var identity_handler = deliveryHandler(&identity_testing, &identity_capture);
    try std.testing.expect(identity_testing.model.workspace.select(identity_testing.previous.tab_id));

    try std.testing.expectError(error.StaleTabCreation, identity_handler.execute(identity_creation));
    try std.testing.expectEqual(@as(usize, 0), identity_capture.event_count);

    var layout_testing = try TestingModel.init();
    defer layout_testing.deinit();
    const layout_creation = try layout_testing.create();
    var layout_capture = captureFor(&layout_testing, layout_creation);
    var layout_handler = deliveryHandler(&layout_testing, &layout_capture);
    layout_testing.model.workspace.find(layout_testing.previous.tab_id).?.model.setPaneGaps(false);

    try std.testing.expectError(error.StaleTabCreation, layout_handler.execute(layout_creation));
    try std.testing.expectEqual(@as(usize, 0), layout_capture.event_count);

    var root_testing = try TestingModel.init();
    defer root_testing.deinit();
    const root_creation = try root_testing.create();
    var root_capture = captureFor(&root_testing, root_creation);
    var root_handler = deliveryHandler(&root_testing, &root_capture);
    root_testing.model.workspace.findPane(root_testing.created_root).?.attached = false;

    try std.testing.expectError(error.StaleTabCreation, root_handler.execute(root_creation));
    try std.testing.expectEqual(@as(usize, 0), root_capture.event_count);

    var pane_testing = try TestingModel.init();
    defer pane_testing.deinit();
    var pane_creation = try pane_testing.create();
    var pane_capture = captureFor(&pane_testing, pane_creation);
    var pane_handler = deliveryHandler(&pane_testing, &pane_capture);
    try pane_testing.model.workspace.active().?.model.split(.{ .existing_pane = pane_testing.created_root, .new_pane = @enumFromInt(4), .location = pane_testing.created, .axis = .vertical, .area = .{ .w = 40, .h = 10 } });
    pane_creation.created_layout_revision =
        pane_testing.model.workspace.activeConst().?.model.layout.currentRevision();

    try std.testing.expectError(error.StaleTabCreation, pane_handler.execute(pane_creation));
    try std.testing.expectEqual(@as(usize, 0), pane_capture.event_count);
}

test "DeliverTabCreationHandler stops after attachment failure without rolling back creation" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const creation = try testing.create();
    var capture = captureFor(&testing, creation);
    capture.failure = .second_detach;
    var handler = deliveryHandler(&testing, &capture);

    try std.testing.expectError(error.DetachFailed, handler.execute(creation));

    try std.testing.expectEqualDeep(testing.created, testing.model.activeTabLocation().?);
    try std.testing.expect(testing.model.workspace.findPane(testing.previous_root).?.attached);
    try std.testing.expect(testing.model.workspace.findPane(testing.previous_sibling).?.attached);
    try std.testing.expect(!testing.model.panePasteActive());
    try std.testing.expect(testing.model.reportedPaneFocus() == null);
    try std.testing.expectEqualDeep(
        Event{ .detach = testing.previous_sibling },
        capture.eventSlice()[capture.event_count - 1],
    );
    try std.testing.expect(capture.committed_creation_observed);
}

test "DeliverTabCreationHandler preserves retired attachments after resource failure" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const creation = try testing.create();
    var capture = captureFor(&testing, creation);
    capture.failure = .active_resources;
    var handler = deliveryHandler(&testing, &capture);

    try std.testing.expectError(error.ActiveResourcesFailed, handler.execute(creation));

    try std.testing.expectEqualDeep(testing.created, testing.model.activeTabLocation().?);
    try std.testing.expect(!testing.model.workspace.findPane(testing.previous_root).?.attached);
    try std.testing.expect(!testing.model.workspace.findPane(testing.previous_sibling).?.attached);
    try std.testing.expectEqual(
        Event.synchronize_active_resources,
        capture.eventSlice()[capture.event_count - 1],
    );
    try std.testing.expect(capture.previous_retired_before_sync);
    try std.testing.expect(capture.committed_creation_observed);
}

test "DeliverTabCreationHandler keeps completed paste retirement after focus failure" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const creation = try testing.create();
    var capture = captureFor(&testing, creation);
    capture.failure = .focus;
    var handler = deliveryHandler(&testing, &capture);

    try std.testing.expectError(error.FocusFailed, handler.execute(creation));

    try std.testing.expect(!testing.model.panePasteActive());
    try std.testing.expect(testing.model.reportedPaneFocus() == null);
    try std.testing.expectEqualDeep(
        Event{ .focus_out = testing.previous_root },
        capture.eventSlice()[capture.event_count - 1],
    );
    try std.testing.expect(capture.committed_creation_observed);
}

test "DeliverTabCreationHandler stops after a failed paste boundary" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const creation = try testing.create();
    var capture = captureFor(&testing, creation);
    capture.failure = .paste;
    var handler = deliveryHandler(&testing, &capture);

    try std.testing.expectError(error.PasteFailed, handler.execute(creation));

    try std.testing.expect(!testing.model.panePasteActive());
    try std.testing.expect(testing.model.reportedPaneFocus() != null);
    try std.testing.expect(testing.model.workspace.findPane(testing.previous_root).?.attached);
    try std.testing.expectEqualDeep(
        Event{ .paste_finish = testing.previous_root },
        capture.eventSlice()[capture.event_count - 1],
    );
    try std.testing.expect(capture.committed_creation_observed);
}
