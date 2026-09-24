const pane_input = @import("../../panes/pane_input.zig");
const pane_focus = @import("../../workspace/pane_focus.zig");
const pane_viewport = @import("../../panes/pane_viewport.zig");
const pane_metadata = @import("../../panes/pane_metadata.zig");
const agent_panes = @import("../../panes/agent_panes.zig");
const tab_selection = @import("../../workspace/tab_selection.zig");
const pane_graphics = @import("../../panes/pane_graphics.zig");
const copy_mode = @import("../../input/copy_mode.zig");
const keyinput = @import("keyinput");
const cellgrid = @import("cellgrid");
const core = @import("telar-core");
const model_data = @import("../../model.zig");
const TestingPaneFrame = @import("TestingPaneFrame.zig");
const ClientModel = @import("../ClientModel.zig");
const std = @import("std");
const ReportedPaneFocus = @import("../ReportedPaneFocus.zig");
const Version = @import("../Version.zig");
const CopyModeProjection = @import("../CopyModeProjection.zig");

fn testingPaneFrame(buffer: []u8, input: TestingPaneFrame) !core.FrameView {
    var spans: [1]core.Span = undefined;
    const encoded_spans: []const core.Span = if (input.cells) |cells| block: {
        spans[0] = .{ .start = 0, .cells = cells };
        break :block &spans;
    } else &.{};
    const encoded = try core.encodePaneFrame(buffer, .{
        .pane_id = input.pane_id,
        .frame_id = input.frame_id,
        .base_frame_id = input.base_frame_id,
        .cols = input.cols,
        .rows = input.rows,
        .cursor = input.cursor,
        .input_modes = input.input_modes,
        .scroll = input.scroll,
        .spans = encoded_spans,
    });

    return (try core.decodeServer(encoded)).pane_frame;
}

test "pane surface toggling needs a focused pane and advances the pane version" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();

    const version = model.version();
    try std.testing.expect(agent_panes.toggleSurface(&model) == null);
    try std.testing.expectEqualDeep(version, model.version());
}

test "pane input planning resolves one attached active target without mutation" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: core.PaneId = @enumFromInt(1);
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = pane_id, .location = location, .size = .{ .cols = 20, .rows = 5 } });
    const pane = model.panes.find(pane_id).?;
    pane.input_modes = .{ .cursor_keys = true, .bracketed_paste = true };
    const inactive_pane: core.PaneId = @enumFromInt(2);
    _ = try model_data.tab_creation.add(&model, .{
        .location = .{
            .workspace = location.workspace,
            .tab_id = @enumFromInt(2),
        },
        .position = 1,
        .label = "inactive",
        .root_pane_id = inactive_pane,
    }, .{ .cols = 20, .rows = 5 });
    model.panes.find(inactive_pane).?.attached = true;
    try std.testing.expect(model_data.tab_selection.select(&model, location.tab_id));
    const version = model.version();
    const expected: model_data.PaneInputPlan = .{
        .pane_id = pane_id,
        .input_modes = pane.input_modes,
    };

    try std.testing.expectEqualDeep(expected, pane_input.planInput(&model, .focused).?);
    try std.testing.expectEqualDeep(expected, pane_input.planInput(&model, .{ .pane = pane_id }).?);
    try std.testing.expect(pane_input.planInput(&model, .{ .pane = inactive_pane }) == null);
    try std.testing.expectEqual(inactive_pane, pane_input.planInput(&model, .{ .key_lease = inactive_pane }).?.pane_id);
    try std.testing.expect(pane_input.planInput(&model, .{ .pane = @enumFromInt(9) }) == null);
    try std.testing.expect(pane_input.planInput(&model, .{ .key_lease = @enumFromInt(9) }) == null);
    try std.testing.expectEqualDeep(version, model.version());

    pane.attached = false;
    try std.testing.expect(pane_input.planInput(&model, .focused) == null);
    try std.testing.expectEqualDeep(version, model.version());
}

test "pane input planning yields ownership to prompts and copy mode" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: core.PaneId = @enumFromInt(1);
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = pane_id, .location = location, .size = .{ .cols = 20, .rows = 5 } });

    model.name_prompt.begin(.create_workspace);
    const prompt_version = model.version();
    try std.testing.expect(pane_input.planInput(&model, .focused) == null);
    try std.testing.expectEqual(pane_id, pane_input.planInput(&model, .{ .key_lease = pane_id }).?.pane_id);
    try std.testing.expectEqualDeep(prompt_version, model.version());

    try std.testing.expect(model.name_prompt.apply(.cancel) == .cancelled);
    try std.testing.expect(copy_mode.enter(&model));
    const copy_version = model.version();
    try std.testing.expect(pane_input.planInput(&model, .{ .pane = pane_id }) == null);
    try std.testing.expectEqual(pane_id, pane_input.planInput(&model, .{ .key_lease = pane_id }).?.pane_id);
    try std.testing.expectEqualDeep(copy_version, model.version());
}

test "reported pane focus derives protocol edges outside presentation versions" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const first: core.PaneId = @enumFromInt(1);
    const second: core.PaneId = @enumFromInt(2);
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = first, .location = location, .size = .{ .cols = 20, .rows = 5 } });
    const version = model.version();

    const disabled = pane_focus.syncReported(&model).?;

    try std.testing.expectEqualDeep(ReportedPaneFocus{
        .pane_id = first,
        .focus_events = false,
    }, disabled.current.?);
    try std.testing.expect(disabled.previous == null);
    try std.testing.expect(disabled.focus_out == null);
    try std.testing.expect(disabled.focus_in == null);
    try std.testing.expect(pane_focus.syncReported(&model) == null);
    try std.testing.expectEqualDeep(version, model.version());

    model.panes.find(first).?.input_modes.focus_events = true;
    const enabled = pane_focus.syncReported(&model).?;
    try std.testing.expectEqual(first, enabled.focus_in.?);
    try std.testing.expect(enabled.focus_out == null);

    try model_data.pane_split.split(&model, model.tabs.active, .{ .existing_pane = first, .new_pane = second, .location = location, .axis = .horizontal, .area = .{ .w = 20, .h = 5 } });
    model.panes.find(second).?.input_modes.focus_events = true;
    const moved = pane_focus.syncReported(&model).?;

    try std.testing.expectEqual(first, moved.focus_out.?);
    try std.testing.expectEqual(second, moved.focus_in.?);
    try std.testing.expectEqualDeep(ReportedPaneFocus{
        .pane_id = second,
        .focus_events = true,
    }, model.reported_pane_focus.?);
    try std.testing.expectEqualDeep(version, model.version());

    model.panes.find(second).?.input_modes.focus_events = false;
    const opted_out = pane_focus.syncReported(&model).?;
    try std.testing.expect(opted_out.focus_out == null);
    try std.testing.expect(opted_out.focus_in == null);
    try std.testing.expect(!model.reported_pane_focus.?.focus_events);
    try std.testing.expectEqualDeep(version, model.version());
}

test "reported pane focus distinguishes intentional clear from stale retirement" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: core.PaneId = @enumFromInt(1);
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = pane_id, .location = location, .size = .{ .cols = 20, .rows = 5 } });
    const pane = model.panes.find(pane_id).?;
    pane.input_modes.focus_events = true;
    _ = pane_focus.syncReported(&model).?;
    const version = model.version();

    pane.attached = false;
    const clear = pane_focus.clearReported(&model).?;
    try std.testing.expect(clear.focus_out == null);
    try std.testing.expect(model.reported_pane_focus == null);
    try std.testing.expect(pane_focus.clearReported(&model) == null);

    _ = pane_focus.syncReported(&model).?;
    try std.testing.expect(!pane_focus.releaseReported(&model, @enumFromInt(9)));
    try std.testing.expect(pane_focus.releaseReported(&model, pane_id));
    try std.testing.expect(!pane_focus.releaseReported(&model, pane_id));

    _ = pane_focus.syncReported(&model).?;
    try std.testing.expect(pane_focus.forgetReported(&model));
    try std.testing.expect(!pane_focus.forgetReported(&model));
    try std.testing.expectEqualDeep(version, model.version());
}

test "pane paste captures one exact target and framing mode outside presentation versions" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: core.PaneId = @enumFromInt(1);
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = pane_id, .location = location, .size = .{ .cols = 20, .rows = 5 } });
    const pane = model.panes.find(pane_id).?;
    pane.input_modes.bracketed_paste = true;
    const version = model.version();

    const session = pane_input.beginPaste(&model).?;

    try std.testing.expectEqualDeep(model_data.PanePasteSession{
        .pane_id = pane_id,
        .bracketed_paste = true,
    }, session);
    try std.testing.expectEqualDeep(session, model.pane_paste.?);
    try std.testing.expect(pane_input.pasteActive(&model));
    try std.testing.expect(pane_input.beginPaste(&model) == null);
    try std.testing.expectEqualDeep(version, model.version());

    const other_location: core.TabLocation = .{
        .workspace = location.workspace,
        .tab_id = @enumFromInt(2),
    };
    _ = try model_data.tab_creation.add(&model, .{
        .location = other_location,
        .position = 1,
        .label = "other",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expectEqualDeep(other_location, model.tabs.location[model.tabs.active]);

    pane.input_modes.bracketed_paste = false;
    model.name_prompt.begin(.create_workspace);
    try std.testing.expect(pane_input.planInput(&model, .focused) == null);
    const captured = pane_input.planInput(&model, .{ .paste_session = session }).?;
    try std.testing.expectEqual(pane_id, captured.pane_id);
    try std.testing.expect(!captured.input_modes.bracketed_paste);

    const wrong = model_data.PanePasteSession{ .pane_id = pane_id, .bracketed_paste = false };
    try std.testing.expect(!pane_input.finishPaste(&model, wrong));
    try std.testing.expect(!pane_input.releasePaste(&model, @enumFromInt(9)));
    try std.testing.expect(pane_input.finishPaste(&model, session));
    try std.testing.expect(!pane_input.pasteActive(&model));
}

test "pane paste release and copy mode keep one input owner" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: core.PaneId = @enumFromInt(1);
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = pane_id, .location = location, .size = .{ .cols = 20, .rows = 5 } });

    _ = pane_input.beginPaste(&model).?;
    try std.testing.expect(!copy_mode.enter(&model));
    try std.testing.expect(pane_input.releasePaste(&model, pane_id));
    try std.testing.expect(!pane_input.releasePaste(&model, pane_id));

    try std.testing.expect(copy_mode.enter(&model));
    try std.testing.expect(pane_input.beginPaste(&model) == null);
}

test "pane frame application commits screen copy state and one frame revision" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: core.PaneId = @enumFromInt(1);
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = pane_id, .location = location, .size = .{ .cols = 2, .rows = 2 } });
    const pane = model.panes.find(pane_id).?;
    pane.scroll = .{ .total_rows = 4, .offset = 2 };
    pane.cursor = .{ .visible = true, .x = 0, .y = 1 };
    try std.testing.expect(copy_mode.enter(&model));
    const cells = [_]cellgrid.Cell{
        .{ .bytes = [_]u8{'x'} ++ [_]u8{0} ** (cellgrid.Cell.max_bytes - 1) },
        .{},
        .{},
        .{},
    };
    var encoded: [512]u8 = undefined;

    const outcome = try model_data.pane_frame.receive(&model, try testingPaneFrame(&encoded, .{
        .pane_id = pane_id,
        .frame_id = 7,
        .cursor = .{ .visible = true, .x = 1, .y = 1 },
        .input_modes = .{ .cursor_keys = true },
        .scroll = .{ .total_rows = 3, .offset = 1 },
        .cells = &cells,
    }));
    const commit = outcome.applied;

    try std.testing.expectEqual(pane_id, commit.pane_id);
    try std.testing.expectEqualDeep(location, commit.location);
    try std.testing.expectEqual(@as(u64, 7), commit.frame_id);
    try std.testing.expect(commit.graphics_visible);
    try std.testing.expect(commit.snapshot);
    try std.testing.expectEqual(@as(u64, 1), commit.spans);
    try std.testing.expectEqual(@as(u64, 4), commit.cells);
    try std.testing.expectEqual(model.version().workspace, commit.workspace_revision);
    try std.testing.expectEqual(model.version().tabs, commit.tabs_revision);
    try std.testing.expectEqual(model.version().active_tab, commit.active_tab_revision);
    try std.testing.expectEqual(model.version().panes, commit.panes_revision);
    try std.testing.expectEqual(@as(u64, 1), commit.frame_revision);
    try std.testing.expectEqualStrings("x", pane.buffer.cells[0].text());
    try std.testing.expect(pane.input_modes.cursor_keys);
    try std.testing.expectEqual(@as(u64, 7), pane.applied_frame_id);
    try std.testing.expectEqual(@as(u64, 7), pane.pending_frame_id);
    try std.testing.expectEqual(@as(u32, 2), copy_mode.currentProjection(&model).?.view.cursor.y);
    try std.testing.expectEqualDeep(Version{ .copy = 2, .frame = 1 }, model.version());
}

test "pane frame application separates detached panes from patch recovery" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: core.PaneId = @enumFromInt(1);
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = pane_id, .location = location, .size = .{ .cols = 2, .rows = 2 } });
    const pane = model.panes.find(pane_id).?;
    pane.applied_frame_id = 3;
    var encoded: [512]u8 = undefined;

    const recovery = try model_data.pane_frame.receive(&model, try testingPaneFrame(&encoded, .{
        .pane_id = pane_id,
        .frame_id = 4,
        .base_frame_id = 2,
    }));

    try std.testing.expectEqualDeep(model_data.PaneFrameRecovery{
        .pane_id = pane_id,
        .known_frame_id = 3,
    }, recovery.resync);
    try std.testing.expectEqualDeep(Version{}, model.version());
    try std.testing.expectEqual(@as(u64, 0), pane.pending_frame_id);

    pane.attached = false;
    const detached = try model_data.pane_frame.receive(&model, try testingPaneFrame(&encoded, .{
        .pane_id = pane_id,
        .frame_id = 5,
        .cells = &[_]cellgrid.Cell{ .{}, .{}, .{}, .{} },
    }));
    try std.testing.expect(detached == .detached);
    try std.testing.expectEqualDeep(Version{}, model.version());

    pane.attached = true;
    const absent = try model_data.pane_frame.receive(&model, try testingPaneFrame(&encoded, .{
        .pane_id = @enumFromInt(9),
        .cells = &[_]cellgrid.Cell{ .{}, .{}, .{}, .{} },
    }));
    try std.testing.expect(absent == .detached);
    try std.testing.expectEqual(@as(u64, 3), pane.applied_frame_id);
    try std.testing.expectEqual(@as(u64, 0), pane.pending_frame_id);
    try std.testing.expectEqualDeep(Version{}, model.version());
}

test "pane frame apply failure does not publish a frame revision" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: core.PaneId = @enumFromInt(1);
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = pane_id, .location = location, .size = .{ .cols = 2, .rows = 2 } });
    const pane = model.panes.find(pane_id).?;
    pane.applied_frame_id = 3;
    var encoded: [256]u8 = undefined;

    try std.testing.expectError(error.PatchSizeMismatch, model_data.pane_frame.receive(&model, try testingPaneFrame(&encoded, .{
        .pane_id = pane_id,
        .frame_id = 4,
        .base_frame_id = 3,
        .cols = 3,
    })));

    try std.testing.expectEqual(@as(u64, 3), pane.applied_frame_id);
    try std.testing.expectEqual(@as(u64, 0), pane.pending_frame_id);
    try std.testing.expectEqualDeep(Version{}, model.version());
}

test "pane graphics fallback versions only semantic changes" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: core.PaneId = @enumFromInt(1);
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = pane_id, .location = location, .size = .{ .cols = 2, .rows = 2 } });

    const shown = pane_graphics.setFallback(&model, pane_id, true).?;

    try std.testing.expect(shown.visible);
    try std.testing.expectEqual(@as(u64, 1), shown.pane_graphics_revision);
    try std.testing.expect(model.panes.find(pane_id).?.graphics_placeholder);
    try std.testing.expectEqualDeep(Version{ .pane_graphics = 1 }, model.version());

    try std.testing.expect(pane_graphics.setFallback(&model, pane_id, true) == null);
    try std.testing.expect(pane_graphics.setFallback(&model, @enumFromInt(9), true) == null);
    try std.testing.expectEqualDeep(Version{ .pane_graphics = 1 }, model.version());

    const hidden = pane_graphics.setFallback(&model, pane_id, false).?;

    try std.testing.expect(!hidden.visible);
    try std.testing.expectEqual(@as(u64, 2), hidden.pane_graphics_revision);
    try std.testing.expect(!model.panes.find(pane_id).?.graphics_placeholder);
    try std.testing.expectEqualDeep(Version{ .pane_graphics = 2 }, model.version());
}

test "pane cwd metadata stores exact paths and versions only display changes" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: core.PaneId = @enumFromInt(1);
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = pane_id, .location = location, .size = .{ .cols = 2, .rows = 2 } });

    const visible = (try pane_metadata.update(&model, .{ .cwd = .{
        .pane_id = pane_id,
        .path = "/work/telar",
    } })).?;

    try std.testing.expectEqual(model_data.PaneMetadataKind.cwd, visible.kind);
    try std.testing.expect(visible.display_changed);
    try std.testing.expectEqual(@as(u64, 1), visible.pane_metadata_revision);
    try std.testing.expectEqual(@as(u64, 0), visible.pane_foreground_revision);
    try std.testing.expectEqualStrings("/work/telar", model.panes.find(pane_id).?.cwdSlice());
    try std.testing.expectEqualDeep(Version{ .pane_metadata = 1 }, model.version());

    const stored = (try pane_metadata.update(&model, .{ .cwd = .{
        .pane_id = pane_id,
        .path = "/other/telar",
    } })).?;

    try std.testing.expect(!stored.display_changed);
    try std.testing.expectEqual(@as(u64, 1), stored.pane_metadata_revision);
    try std.testing.expectEqualStrings("/other/telar", model.panes.find(pane_id).?.cwdSlice());
    try std.testing.expectEqualDeep(Version{ .pane_metadata = 1 }, model.version());
    try std.testing.expect((try pane_metadata.update(&model, .{ .cwd = .{
        .pane_id = pane_id,
        .path = "/other/telar",
    } })) == null);
    try std.testing.expect((try pane_metadata.update(&model, .{ .cwd = .{
        .pane_id = @enumFromInt(9),
        .path = "/missing",
    } })) == null);

    _ = (try pane_metadata.update(&model, .{ .cwd = .{
        .pane_id = pane_id,
        .path = "/other/api",
    } })).?;
    try std.testing.expectEqualDeep(Version{ .pane_metadata = 2 }, model.version());
}

test "pane foreground metadata versions display changes independently" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: core.PaneId = @enumFromInt(1);
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = pane_id, .location = location, .size = .{ .cols = 2, .rows = 2 } });

    const first = (try pane_metadata.update(&model, .{ .foreground = .{
        .pane_id = pane_id,
        .name = "zsh",
    } })).?;

    try std.testing.expectEqual(model_data.PaneMetadataKind.foreground, first.kind);
    try std.testing.expect(first.display_changed);
    try std.testing.expectEqual(@as(u64, 1), first.pane_metadata_revision);
    try std.testing.expectEqual(@as(u64, 1), first.pane_foreground_revision);
    try std.testing.expectEqualStrings("zsh", model.panes.find(pane_id).?.foregroundName());
    try std.testing.expectEqualDeep(Version{
        .pane_metadata = 1,
        .pane_foreground = 1,
    }, model.version());
    try std.testing.expect((try pane_metadata.update(&model, .{ .foreground = .{
        .pane_id = pane_id,
        .name = "zsh",
    } })) == null);
    try std.testing.expect((try pane_metadata.update(&model, .{ .foreground = .{
        .pane_id = @enumFromInt(9),
        .name = "bash",
    } })) == null);

    _ = (try pane_metadata.update(&model, .{ .foreground = .{
        .pane_id = pane_id,
        .name = "bash",
    } })).?;
    try std.testing.expectEqualDeep(Version{
        .pane_metadata = 2,
        .pane_foreground = 2,
    }, model.version());
}

test "pane cwd allocation failure preserves metadata and revisions" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: core.PaneId = @enumFromInt(1);
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = pane_id, .location = location, .size = .{ .cols = 2, .rows = 2 } });
    _ = (try pane_metadata.update(&model, .{ .cwd = .{
        .pane_id = pane_id,
        .path = "/work/telar",
    } })).?;
    const pane = model.panes.find(pane_id).?;
    const version = model.version();
    const original_gpa = pane.gpa;
    pane.gpa = std.testing.failing_allocator;
    const result = pane_metadata.update(&model, .{ .cwd = .{
        .pane_id = pane_id,
        .path = "/work/api",
    } });
    pane.gpa = original_gpa;

    try std.testing.expectError(error.OutOfMemory, result);
    try std.testing.expectEqualStrings("/work/telar", pane.cwdSlice());
    try std.testing.expectEqualDeep(version, model.version());
}

test "pane viewport intents are bounded versioned and reserved by copy mode" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: core.PaneId = @enumFromInt(1);
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = pane_id, .location = location, .size = .{ .cols = 20, .rows = 5 } });
    const pane = model.panes.find(pane_id).?;
    pane.scroll = .{ .total_rows = 20, .offset = 10 };
    pane.cursor = .{ .visible = true, .x = 2, .y = 4 };

    const top = pane_viewport.set(&model, .{
        .pane_id = pane_id,
        .target = .{ .relative = -100 },
    }).?;

    try std.testing.expectEqual(@as(u32, 0), top.offset);
    try std.testing.expect(!top.at_bottom);
    try std.testing.expectEqual(@as(u64, 1), top.viewport_revision);
    try std.testing.expectEqualDeep(Version{ .viewport = 1 }, model.version());
    try std.testing.expect(pane_viewport.set(&model, .{
        .pane_id = pane_id,
        .target = .{ .absolute = 0 },
    }) == null);

    const bottom = pane_viewport.set(&model, .{
        .pane_id = pane_id,
        .target = .{ .absolute = std.math.maxInt(u32) },
    }).?;

    try std.testing.expectEqual(@as(u32, 15), bottom.offset);
    try std.testing.expect(bottom.at_bottom);
    try std.testing.expectEqual(@as(u64, 2), bottom.viewport_revision);
    try std.testing.expect(pane_viewport.set(&model, .{
        .pane_id = pane_id,
        .target = .bottom,
    }) == null);
    try std.testing.expect(pane_viewport.set(&model, .{
        .pane_id = @enumFromInt(9),
        .target = .bottom,
    }) == null);
    try std.testing.expectEqualDeep(Version{ .viewport = 2 }, model.version());

    pane.scroll.offset = 10;
    try std.testing.expect(copy_mode.enter(&model));
    const copy_version = model.version();
    try std.testing.expect(pane_viewport.set(&model, .{
        .pane_id = pane_id,
        .target = .bottom,
    }) == null);
    try std.testing.expectEqualDeep(copy_version, model.version());

    const copy_commit = copy_mode.commitPlan(&model, copy_mode.planCommand(&model, .{
        .key = try keyinput.chord.parseKey("g"),
    }).?).?;

    try std.testing.expectEqual(@as(u32, 0), copy_commit.viewport.?.offset);
    try std.testing.expectEqual(@as(u64, 3), copy_commit.viewport.?.viewport_revision);
    try std.testing.expectEqual(copy_version.copy + 1, model.version().copy);
    try std.testing.expectEqual(copy_version.viewport + 1, model.version().viewport);
}

test "copy mode entry owns one independent model revision" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: core.PaneId = @enumFromInt(1);
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = pane_id, .location = location, .size = .{ .cols = 20, .rows = 5 } });
    const pane = model.panes.find(pane_id).?;
    pane.scroll = .{ .total_rows = 15, .offset = 10 };
    pane.cursor = .{ .visible = true, .x = 4, .y = 2 };

    try std.testing.expect(copy_mode.targetPane(&model) == null);
    try std.testing.expect(copy_mode.enter(&model));

    try std.testing.expect(copy_mode.isActive(&model));
    try std.testing.expectEqual(pane_id, copy_mode.targetPane(&model).?);
    try std.testing.expectEqualDeep(CopyModeProjection{
        .pane_id = pane_id,
        .view = .{
            .cursor = .{ .x = 4, .y = 12 },
            .anchor = null,
            .linewise = false,
        },
    }, copy_mode.currentProjection(&model).?);
    try std.testing.expectEqualDeep(Version{ .copy = 1 }, model.version());
    try std.testing.expect(!copy_mode.enter(&model));
    try std.testing.expectEqualDeep(Version{ .copy = 1 }, model.version());

    const leave = copy_mode.planCommand(&model, .leave).?;
    _ = copy_mode.commitPlan(&model, leave).?;
    model.name_prompt.begin(.create_workspace);
    const copy_revision = model.version().copy;

    try std.testing.expect(!copy_mode.enter(&model));
    try std.testing.expectEqual(copy_revision, model.version().copy);
}

test "copy mode plans reject no-ops and stale commits" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 20, .rows = 5 } });
    try std.testing.expect(copy_mode.enter(&model));
    const version = model.version();

    try std.testing.expect(copy_mode.planCommand(&model, .{ .key = try keyinput.chord.parseKey("left") }) == null);
    try std.testing.expect(copy_mode.planCommand(&model, .{ .key = try keyinput.chord.parseKey("z") }) == null);
    try std.testing.expectEqualDeep(version, model.version());

    const first = copy_mode.planCommand(&model, .{ .key = try keyinput.chord.parseKey("right") }).?;
    const stale = copy_mode.planCommand(&model, .{ .key = try keyinput.chord.parseKey("right") }).?;
    const commit = copy_mode.commitPlan(&model, first).?;

    try std.testing.expect(commit.active);
    try std.testing.expectEqual(version.copy + 1, commit.copy_revision);
    try std.testing.expect(copy_mode.commitPlan(&model, stale) == null);
    try std.testing.expectEqual(version.copy + 1, model.version().copy);
}

test "copy mode plans the textual link under its cursor without mutation" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: core.PaneId = @enumFromInt(1);
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = pane_id, .location = location, .size = .{ .cols = 40, .rows = 5 } });
    const pane = model.panes.find(pane_id).?;
    pane.buffer.fill(pane.buffer.area(), .{ .glyph = " ", .style = .{} });
    _ = pane.buffer.writeText(pane.buffer.area(), .{ .point = .{ .x = 0, .y = 2 }, .text = "file:///tmp/a%20b.txt", .style = .{} });
    pane.cursor = .{ .visible = true, .x = 12, .y = 2 };
    try std.testing.expect(copy_mode.enter(&model));
    const version = model.version();

    const plan = copy_mode.planCommand(&model, .{ .key = try keyinput.chord.parseKey("o") }).?;

    try std.testing.expectEqualStrings("file:///tmp/a%20b.txt", plan.open_link.?.uri());
    try std.testing.expectEqualDeep(version, model.version());
    try std.testing.expect(copy_mode.planCommand(&model, .{ .key = try keyinput.chord.parseKey("o") }) != null);

    pane.buffer.fill(pane.buffer.area(), .{ .glyph = " ", .style = .{} });
    try std.testing.expect(copy_mode.planCommand(&model, .{ .key = try keyinput.chord.parseKey("o") }) == null);
}

test "an active tab transition releases copy authority" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();
    const workspace: core.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first: core.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(1) };
    const second: core.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(2) };
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = @enumFromInt(1), .location = first, .size = .{ .cols = 20, .rows = 5 } });
    _ = try model_data.tab_creation.add(&model, .{
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(model_data.tab_selection.select(&model, first.tab_id));
    try std.testing.expect(copy_mode.enter(&model));
    const version = model.version();

    const selection = (try tab_selection.commitSelection(&model, .{ .tab_id = second.tab_id })).?;

    try std.testing.expectEqualDeep(first, selection.previous);
    try std.testing.expectEqualDeep(second, selection.selected);
    try std.testing.expectEqual(model.version().copy, selection.copy_revision);
    try std.testing.expect(!copy_mode.isActive(&model));
    try std.testing.expectEqual(version.active_tab + 1, model.version().active_tab);
    try std.testing.expectEqual(version.copy + 1, model.version().copy);
}
