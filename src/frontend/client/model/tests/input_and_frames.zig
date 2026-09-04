const std = @import("std");
const core = @import("telar-core");
const agents = @import("../../../agents/root.zig");
const attachments = @import("../../../attachments/root.zig");
const lua_config = @import("../../../config/root.zig");
const graphics = @import("../../../graphics/root.zig");
const input_capability = @import("../../../input/root.zig");
const notifications = @import("../../../notifications/root.zig");
const workspace_capability = @import("../../../workspace/root.zig");
const client_model = @import("../root.zig");

const copy_mode = input_capability.copy_mode;
const keybind = input_capability.keybind;
const kitty = graphics.kitty;
const schema = core.schema;
const layout_mod = workspace_capability.layout;
const multiplexer = workspace_capability.multiplexer;
const tabs_mod = workspace_capability.tabs;
const workspace_list_mod = workspace_capability.workspace_list;
const ui = core.ui;

const TestingPaneFrame = struct {
    pane_id: schema.PaneId,
    frame_id: u64 = 1,
    base_frame_id: u64 = 0,
    cols: u16 = 2,
    rows: u16 = 2,
    cursor: schema.frame.Cursor = .{},
    input_modes: schema.frame.InputModes = .{},
    scroll: schema.frame.Scroll = .{ .total_rows = 2, .offset = 0 },
    cells: ?[]const ui.Cell = null,
};

fn testingPaneFrame(buffer: []u8, input: TestingPaneFrame) !schema.frame.FrameView {
    var spans: [1]schema.frame.Span = undefined;
    const encoded_spans: []const schema.frame.Span = if (input.cells) |cells| block: {
        spans[0] = .{ .start = 0, .cells = cells };
        break :block &spans;
    } else &.{};
    const encoded = try schema.encodePaneFrame(buffer, .{
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

    return (try schema.decodeServer(encoded)).pane_frame;
}

test "pane input planning resolves one attached active target without mutation" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(pane_id, location, .{ .cols = 20, .rows = 5 });
    const pane = model.workspace.findPane(pane_id).?;
    pane.input_modes = .{ .cursor_keys = true, .bracketed_paste = true };
    const inactive_pane: schema.PaneId = @enumFromInt(2);
    _ = try model.workspace.addCreated(.{
        .location = .{
            .workspace = location.workspace,
            .tab_id = @enumFromInt(2),
        },
        .position = 1,
        .label = "inactive",
        .root_pane_id = inactive_pane,
    }, .{ .cols = 20, .rows = 5 });
    model.workspace.findPane(inactive_pane).?.attached = true;
    try std.testing.expect(model.workspace.select(location.tab_id));
    const version = model.version();
    const expected: client_model.PaneInputPlan = .{
        .pane_id = pane_id,
        .input_modes = pane.input_modes,
    };

    try std.testing.expectEqualDeep(expected, model.planPaneInput(.focused).?);
    try std.testing.expectEqualDeep(expected, model.planPaneInput(.{ .pane = pane_id }).?);
    try std.testing.expect(model.planPaneInput(.{ .pane = inactive_pane }) == null);
    try std.testing.expectEqual(inactive_pane, model.planPaneInput(.{ .key_lease = inactive_pane }).?.pane_id);
    try std.testing.expect(model.planPaneInput(.{ .pane = @enumFromInt(9) }) == null);
    try std.testing.expect(model.planPaneInput(.{ .key_lease = @enumFromInt(9) }) == null);
    try std.testing.expectEqualDeep(version, model.version());

    pane.attached = false;
    try std.testing.expect(model.planPaneInput(.focused) == null);
    try std.testing.expectEqualDeep(version, model.version());
}

test "pane input planning yields ownership to prompts and copy mode" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(pane_id, location, .{ .cols = 20, .rows = 5 });

    model.name_prompt.begin(.create_workspace);
    const prompt_version = model.version();
    try std.testing.expect(model.planPaneInput(.focused) == null);
    try std.testing.expectEqual(pane_id, model.planPaneInput(.{ .key_lease = pane_id }).?.pane_id);
    try std.testing.expectEqualDeep(prompt_version, model.version());

    try std.testing.expect(model.name_prompt.apply(.cancel) == .cancelled);
    try std.testing.expect(model.enterCopyMode());
    const copy_version = model.version();
    try std.testing.expect(model.planPaneInput(.{ .pane = pane_id }) == null);
    try std.testing.expectEqual(pane_id, model.planPaneInput(.{ .key_lease = pane_id }).?.pane_id);
    try std.testing.expectEqualDeep(copy_version, model.version());
}

test "reported pane focus derives protocol edges outside presentation versions" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const first: schema.PaneId = @enumFromInt(1);
    const second: schema.PaneId = @enumFromInt(2);
    try model.workspace.bootstrap(first, location, .{ .cols = 20, .rows = 5 });
    const version = model.version();

    const disabled = model.syncReportedPaneFocus().?;

    try std.testing.expectEqualDeep(client_model.ReportedPaneFocus{
        .pane_id = first,
        .focus_events = false,
    }, disabled.current.?);
    try std.testing.expect(disabled.previous == null);
    try std.testing.expect(disabled.focus_out == null);
    try std.testing.expect(disabled.focus_in == null);
    try std.testing.expect(model.syncReportedPaneFocus() == null);
    try std.testing.expectEqualDeep(version, model.version());

    model.workspace.findPane(first).?.input_modes.focus_events = true;
    const enabled = model.syncReportedPaneFocus().?;
    try std.testing.expectEqual(first, enabled.focus_in.?);
    try std.testing.expect(enabled.focus_out == null);

    try model.workspace.active().?.model.split(.{ .existing_pane = first, .new_pane = second, .location = location, .axis = .horizontal, .area = .{ .w = 20, .h = 5 } });
    model.workspace.findPane(second).?.input_modes.focus_events = true;
    const moved = model.syncReportedPaneFocus().?;

    try std.testing.expectEqual(first, moved.focus_out.?);
    try std.testing.expectEqual(second, moved.focus_in.?);
    try std.testing.expectEqualDeep(client_model.ReportedPaneFocus{
        .pane_id = second,
        .focus_events = true,
    }, model.reportedPaneFocus().?);
    try std.testing.expectEqualDeep(version, model.version());

    model.workspace.findPane(second).?.input_modes.focus_events = false;
    const opted_out = model.syncReportedPaneFocus().?;
    try std.testing.expect(opted_out.focus_out == null);
    try std.testing.expect(opted_out.focus_in == null);
    try std.testing.expect(!model.reportedPaneFocus().?.focus_events);
    try std.testing.expectEqualDeep(version, model.version());
}

test "reported pane focus distinguishes intentional clear from stale retirement" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(pane_id, location, .{ .cols = 20, .rows = 5 });
    const pane = model.workspace.findPane(pane_id).?;
    pane.input_modes.focus_events = true;
    _ = model.syncReportedPaneFocus().?;
    const version = model.version();

    pane.attached = false;
    const clear = model.clearReportedPaneFocus().?;
    try std.testing.expect(clear.focus_out == null);
    try std.testing.expect(model.reportedPaneFocus() == null);
    try std.testing.expect(model.clearReportedPaneFocus() == null);

    _ = model.syncReportedPaneFocus().?;
    try std.testing.expect(!model.releaseReportedPaneFocus(@enumFromInt(9)));
    try std.testing.expect(model.releaseReportedPaneFocus(pane_id));
    try std.testing.expect(!model.releaseReportedPaneFocus(pane_id));

    _ = model.syncReportedPaneFocus().?;
    try std.testing.expect(model.forgetReportedPaneFocus());
    try std.testing.expect(!model.forgetReportedPaneFocus());
    try std.testing.expectEqualDeep(version, model.version());
}

test "pane paste captures one exact target and framing mode outside presentation versions" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(pane_id, location, .{ .cols = 20, .rows = 5 });
    const pane = model.workspace.findPane(pane_id).?;
    pane.input_modes.bracketed_paste = true;
    const version = model.version();

    const session = model.beginPanePaste().?;

    try std.testing.expectEqualDeep(client_model.PanePasteSession{
        .pane_id = pane_id,
        .bracketed_paste = true,
    }, session);
    try std.testing.expectEqualDeep(session, model.panePasteSession().?);
    try std.testing.expect(model.panePasteActive());
    try std.testing.expect(model.beginPanePaste() == null);
    try std.testing.expectEqualDeep(version, model.version());

    const other_location: schema.TabLocation = .{
        .workspace = location.workspace,
        .tab_id = @enumFromInt(2),
    };
    _ = try model.workspace.addCreated(.{
        .location = other_location,
        .position = 1,
        .label = "other",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expectEqualDeep(other_location, model.workspace.activeConst().?.location);

    pane.input_modes.bracketed_paste = false;
    model.name_prompt.begin(.create_workspace);
    try std.testing.expect(model.planPaneInput(.focused) == null);
    const captured = model.planPaneInput(.{ .paste_session = session }).?;
    try std.testing.expectEqual(pane_id, captured.pane_id);
    try std.testing.expect(!captured.input_modes.bracketed_paste);

    const wrong = client_model.PanePasteSession{ .pane_id = pane_id, .bracketed_paste = false };
    try std.testing.expect(!model.finishPanePaste(wrong));
    try std.testing.expect(!model.releasePanePaste(@enumFromInt(9)));
    try std.testing.expect(model.finishPanePaste(session));
    try std.testing.expect(!model.panePasteActive());
}

test "pane paste release and copy mode keep one input owner" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(pane_id, location, .{ .cols = 20, .rows = 5 });

    _ = model.beginPanePaste().?;
    try std.testing.expect(!model.enterCopyMode());
    try std.testing.expect(model.releasePanePaste(pane_id));
    try std.testing.expect(!model.releasePanePaste(pane_id));

    try std.testing.expect(model.enterCopyMode());
    try std.testing.expect(model.beginPanePaste() == null);
}

test "pane frame application commits screen copy state and one frame revision" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(pane_id, location, .{ .cols = 2, .rows = 2 });
    const pane = model.workspace.findPane(pane_id).?;
    pane.scroll = .{ .total_rows = 4, .offset = 2 };
    pane.cursor = .{ .visible = true, .x = 0, .y = 1 };
    try std.testing.expect(model.enterCopyMode());
    const cells = [_]ui.Cell{
        .{ .bytes = [_]u8{'x'} ++ [_]u8{0} ** (ui.Cell.max_bytes - 1) },
        .{},
        .{},
        .{},
    };
    var encoded: [512]u8 = undefined;

    const outcome = try model.applyPaneFrame(try testingPaneFrame(&encoded, .{
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
    try std.testing.expectEqual(@as(u32, 2), model.copyModeProjection().?.view.cursor.y);
    try std.testing.expectEqualDeep(client_model.Version{ .copy = 2, .frame = 1 }, model.version());
}

test "pane frame application separates stale detach recovery and invalid input" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(pane_id, location, .{ .cols = 2, .rows = 2 });
    const pane = model.workspace.findPane(pane_id).?;
    pane.applied_frame_id = 3;
    var encoded: [512]u8 = undefined;

    const recovery = try model.applyPaneFrame(try testingPaneFrame(&encoded, .{
        .pane_id = pane_id,
        .frame_id = 4,
        .base_frame_id = 2,
    }));

    try std.testing.expectEqualDeep(client_model.PaneFrameRecovery{
        .pane_id = pane_id,
        .known_frame_id = 3,
    }, recovery.resync);
    try std.testing.expectEqualDeep(client_model.Version{}, model.version());
    try std.testing.expectEqual(@as(u64, 0), pane.pending_frame_id);

    pane.attached = false;
    const detached = try model.applyPaneFrame(try testingPaneFrame(&encoded, .{
        .pane_id = pane_id,
        .frame_id = 5,
        .cells = &[_]ui.Cell{ .{}, .{}, .{}, .{} },
    }));
    try std.testing.expect(detached == .detached);
    try std.testing.expectEqualDeep(client_model.Version{}, model.version());

    try std.testing.expectError(error.UnexpectedPane, model.applyPaneFrame(try testingPaneFrame(&encoded, .{
        .pane_id = @enumFromInt(9),
        .cells = &[_]ui.Cell{ .{}, .{}, .{}, .{} },
    })));
    try std.testing.expectEqualDeep(client_model.Version{}, model.version());
}

test "pane frame apply failure does not publish a frame revision" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(pane_id, location, .{ .cols = 2, .rows = 2 });
    const pane = model.workspace.findPane(pane_id).?;
    pane.applied_frame_id = 3;
    var encoded: [256]u8 = undefined;

    try std.testing.expectError(error.PatchSizeMismatch, model.applyPaneFrame(try testingPaneFrame(&encoded, .{
        .pane_id = pane_id,
        .frame_id = 4,
        .base_frame_id = 3,
        .cols = 3,
    })));

    try std.testing.expectEqual(@as(u64, 3), pane.applied_frame_id);
    try std.testing.expectEqual(@as(u64, 0), pane.pending_frame_id);
    try std.testing.expectEqualDeep(client_model.Version{}, model.version());
}

test "pane graphics fallback versions only semantic changes" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(pane_id, location, .{ .cols = 2, .rows = 2 });
    const tab = model.workspace.active().?;

    const shown = model.setPaneGraphicsFallback(pane_id, true).?;

    try std.testing.expect(shown.visible);
    try std.testing.expectEqual(@as(u64, 1), shown.pane_graphics_revision);
    try std.testing.expect(tab.model.find(pane_id).?.graphics_placeholder);
    try std.testing.expectEqualDeep(client_model.Version{ .pane_graphics = 1 }, model.version());

    try std.testing.expect(model.setPaneGraphicsFallback(pane_id, true) == null);
    try std.testing.expect(model.setPaneGraphicsFallback(@enumFromInt(9), true) == null);
    try std.testing.expectEqualDeep(client_model.Version{ .pane_graphics = 1 }, model.version());

    const hidden = model.setPaneGraphicsFallback(pane_id, false).?;

    try std.testing.expect(!hidden.visible);
    try std.testing.expectEqual(@as(u64, 2), hidden.pane_graphics_revision);
    try std.testing.expect(!tab.model.find(pane_id).?.graphics_placeholder);
    try std.testing.expectEqualDeep(client_model.Version{ .pane_graphics = 2 }, model.version());
}

test "pane cwd metadata stores exact paths and versions only display changes" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(pane_id, location, .{ .cols = 2, .rows = 2 });
    const tab = model.workspace.active().?;

    const visible = (try model.updatePaneMetadata(.{ .cwd = .{
        .pane_id = pane_id,
        .path = "/work/telar",
    } })).?;

    try std.testing.expectEqual(client_model.PaneMetadataKind.cwd, visible.kind);
    try std.testing.expect(visible.display_changed);
    try std.testing.expectEqual(@as(u64, 1), visible.pane_metadata_revision);
    try std.testing.expectEqual(@as(u64, 0), visible.pane_foreground_revision);
    try std.testing.expectEqualStrings("/work/telar", tab.model.find(pane_id).?.cwdSlice());
    try std.testing.expectEqualDeep(client_model.Version{ .pane_metadata = 1 }, model.version());

    const stored = (try model.updatePaneMetadata(.{ .cwd = .{
        .pane_id = pane_id,
        .path = "/other/telar",
    } })).?;

    try std.testing.expect(!stored.display_changed);
    try std.testing.expectEqual(@as(u64, 1), stored.pane_metadata_revision);
    try std.testing.expectEqualStrings("/other/telar", tab.model.find(pane_id).?.cwdSlice());
    try std.testing.expectEqualDeep(client_model.Version{ .pane_metadata = 1 }, model.version());
    try std.testing.expect((try model.updatePaneMetadata(.{ .cwd = .{
        .pane_id = pane_id,
        .path = "/other/telar",
    } })) == null);
    try std.testing.expect((try model.updatePaneMetadata(.{ .cwd = .{
        .pane_id = @enumFromInt(9),
        .path = "/missing",
    } })) == null);

    _ = (try model.updatePaneMetadata(.{ .cwd = .{
        .pane_id = pane_id,
        .path = "/other/api",
    } })).?;
    try std.testing.expectEqualDeep(client_model.Version{ .pane_metadata = 2 }, model.version());
}

test "pane foreground metadata versions display changes independently" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(pane_id, location, .{ .cols = 2, .rows = 2 });
    const tab = model.workspace.active().?;

    const first = (try model.updatePaneMetadata(.{ .foreground = .{
        .pane_id = pane_id,
        .name = "zsh",
    } })).?;

    try std.testing.expectEqual(client_model.PaneMetadataKind.foreground, first.kind);
    try std.testing.expect(first.display_changed);
    try std.testing.expectEqual(@as(u64, 1), first.pane_metadata_revision);
    try std.testing.expectEqual(@as(u64, 1), first.pane_foreground_revision);
    try std.testing.expectEqualStrings("zsh", tab.model.find(pane_id).?.foregroundName());
    try std.testing.expectEqualDeep(client_model.Version{
        .pane_metadata = 1,
        .pane_foreground = 1,
    }, model.version());
    try std.testing.expect((try model.updatePaneMetadata(.{ .foreground = .{
        .pane_id = pane_id,
        .name = "zsh",
    } })) == null);
    try std.testing.expect((try model.updatePaneMetadata(.{ .foreground = .{
        .pane_id = @enumFromInt(9),
        .name = "bash",
    } })) == null);

    _ = (try model.updatePaneMetadata(.{ .foreground = .{
        .pane_id = pane_id,
        .name = "bash",
    } })).?;
    try std.testing.expectEqualDeep(client_model.Version{
        .pane_metadata = 2,
        .pane_foreground = 2,
    }, model.version());
}

test "pane cwd allocation failure preserves metadata and revisions" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(pane_id, location, .{ .cols = 2, .rows = 2 });
    _ = (try model.updatePaneMetadata(.{ .cwd = .{
        .pane_id = pane_id,
        .path = "/work/telar",
    } })).?;
    const pane = model.workspace.findPane(pane_id).?;
    const version = model.version();
    const original_gpa = pane.gpa;
    pane.gpa = std.testing.failing_allocator;
    const result = model.updatePaneMetadata(.{ .cwd = .{
        .pane_id = pane_id,
        .path = "/work/api",
    } });
    pane.gpa = original_gpa;

    try std.testing.expectError(error.OutOfMemory, result);
    try std.testing.expectEqualStrings("/work/telar", pane.cwdSlice());
    try std.testing.expectEqualDeep(version, model.version());
}

test "pane viewport intents are bounded versioned and reserved by copy mode" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(pane_id, location, .{ .cols = 20, .rows = 5 });
    const pane = model.workspace.findPane(pane_id).?;
    pane.scroll = .{ .total_rows = 20, .offset = 10 };
    pane.cursor = .{ .visible = true, .x = 2, .y = 4 };

    const top = model.setPaneViewport(.{
        .pane_id = pane_id,
        .target = .{ .relative = -100 },
    }).?;

    try std.testing.expectEqual(@as(u32, 0), top.offset);
    try std.testing.expect(!top.at_bottom);
    try std.testing.expectEqual(@as(u64, 1), top.viewport_revision);
    try std.testing.expectEqualDeep(client_model.Version{ .viewport = 1 }, model.version());
    try std.testing.expect(model.setPaneViewport(.{
        .pane_id = pane_id,
        .target = .{ .absolute = 0 },
    }) == null);

    const bottom = model.setPaneViewport(.{
        .pane_id = pane_id,
        .target = .{ .absolute = std.math.maxInt(u32) },
    }).?;

    try std.testing.expectEqual(@as(u32, 15), bottom.offset);
    try std.testing.expect(bottom.at_bottom);
    try std.testing.expectEqual(@as(u64, 2), bottom.viewport_revision);
    try std.testing.expect(model.setPaneViewport(.{
        .pane_id = pane_id,
        .target = .bottom,
    }) == null);
    try std.testing.expect(model.setPaneViewport(.{
        .pane_id = @enumFromInt(9),
        .target = .bottom,
    }) == null);
    try std.testing.expectEqualDeep(client_model.Version{ .viewport = 2 }, model.version());

    pane.scroll.offset = 10;
    try std.testing.expect(model.enterCopyMode());
    const copy_version = model.version();
    try std.testing.expect(model.setPaneViewport(.{
        .pane_id = pane_id,
        .target = .bottom,
    }) == null);
    try std.testing.expectEqualDeep(copy_version, model.version());

    const copy_commit = model.commitCopyMode(model.planCopyMode(.{
        .key = try keybind.parseKey("g"),
    }).?).?;

    try std.testing.expectEqual(@as(u32, 0), copy_commit.viewport.?.offset);
    try std.testing.expectEqual(@as(u64, 3), copy_commit.viewport.?.viewport_revision);
    try std.testing.expectEqual(copy_version.copy + 1, model.version().copy);
    try std.testing.expectEqual(copy_version.viewport + 1, model.version().viewport);
}

test "copy mode entry owns one independent model revision" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(pane_id, location, .{ .cols = 20, .rows = 5 });
    const pane = model.workspace.findPane(pane_id).?;
    pane.scroll = .{ .total_rows = 15, .offset = 10 };
    pane.cursor = .{ .visible = true, .x = 4, .y = 2 };

    try std.testing.expect(model.copyModeTarget() == null);
    try std.testing.expect(model.enterCopyMode());

    try std.testing.expect(model.copyModeActive());
    try std.testing.expectEqual(pane_id, model.copyModeTarget().?);
    try std.testing.expectEqualDeep(client_model.CopyModeProjection{
        .pane_id = pane_id,
        .view = .{
            .cursor = .{ .x = 4, .y = 12 },
            .anchor = null,
            .linewise = false,
        },
    }, model.copyModeProjection().?);
    try std.testing.expectEqualDeep(client_model.Version{ .copy = 1 }, model.version());
    try std.testing.expect(!model.enterCopyMode());
    try std.testing.expectEqualDeep(client_model.Version{ .copy = 1 }, model.version());

    const leave = model.planCopyMode(.leave).?;
    _ = model.commitCopyMode(leave).?;
    model.name_prompt.begin(.create_workspace);
    const copy_revision = model.version().copy;

    try std.testing.expect(!model.enterCopyMode());
    try std.testing.expectEqual(copy_revision, model.version().copy);
}

test "copy mode plans reject no-ops and stale commits" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.workspace.bootstrap(@enumFromInt(1), location, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(model.enterCopyMode());
    const version = model.version();

    try std.testing.expect(model.planCopyMode(.{ .key = try keybind.parseKey("left") }) == null);
    try std.testing.expect(model.planCopyMode(.{ .key = try keybind.parseKey("z") }) == null);
    try std.testing.expectEqualDeep(version, model.version());

    const first = model.planCopyMode(.{ .key = try keybind.parseKey("right") }).?;
    const stale = model.planCopyMode(.{ .key = try keybind.parseKey("right") }).?;
    const commit = model.commitCopyMode(first).?;

    try std.testing.expect(commit.active);
    try std.testing.expectEqual(version.copy + 1, commit.copy_revision);
    try std.testing.expect(model.commitCopyMode(stale) == null);
    try std.testing.expectEqual(version.copy + 1, model.version().copy);
}

test "copy mode plans the textual link under its cursor without mutation" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(pane_id, location, .{ .cols = 40, .rows = 5 });
    const pane = model.workspace.findPane(pane_id).?;
    pane.buffer.fill(pane.buffer.area(), .{ .glyph = " ", .style = .{} });
    _ = pane.buffer.writeText(pane.buffer.area(), .{ .point = .{ .x = 0, .y = 2 }, .text = "file:///tmp/a%20b.txt", .style = .{} });
    pane.cursor = .{ .visible = true, .x = 12, .y = 2 };
    try std.testing.expect(model.enterCopyMode());
    const version = model.version();

    const plan = model.planCopyMode(.{ .key = try keybind.parseKey("o") }).?;

    try std.testing.expectEqualStrings("file:///tmp/a%20b.txt", plan.open_link.?.uri());
    try std.testing.expectEqualDeep(version, model.version());
    try std.testing.expect(model.planCopyMode(.{ .key = try keybind.parseKey("o") }) != null);

    pane.buffer.fill(pane.buffer.area(), .{ .glyph = " ", .style = .{} });
    try std.testing.expect(model.planCopyMode(.{ .key = try keybind.parseKey("o") }) == null);
}

test "an active tab transition releases copy authority" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first: schema.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(1) };
    const second: schema.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(2) };
    try model.workspace.bootstrap(@enumFromInt(1), first, .{ .cols = 20, .rows = 5 });
    _ = try model.workspace.addCreated(.{
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(model.workspace.select(first.tab_id));
    try std.testing.expect(model.enterCopyMode());
    const version = model.version();

    const selection = (try model.selectTab(.{ .tab_id = second.tab_id })).?;

    try std.testing.expectEqualDeep(first, selection.previous);
    try std.testing.expectEqualDeep(second, selection.selected);
    try std.testing.expectEqual(model.version().copy, selection.copy_revision);
    try std.testing.expect(!model.copyModeActive());
    try std.testing.expectEqual(version.active_tab + 1, model.version().active_tab);
    try std.testing.expectEqual(version.copy + 1, model.version().copy);
}
