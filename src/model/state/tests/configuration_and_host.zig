const core = @import("telar-core");
const model_data = @import("../../model.zig");
const ClientModel = @import("../ClientModel.zig");
const std = @import("std");
const Version = @import("../Version.zig");
const EntryInput = @import("../../workspace/EntryInput.zig");

test "sidebar visibility advances only the chrome revision" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();

    try std.testing.expect(model.sidebar_visible);
    try std.testing.expect(model.setSidebarVisible(true) == null);
    try std.testing.expectEqualDeep(Version{}, model.version());

    const hidden = model.toggleSidebar();

    try std.testing.expect(!hidden.visible);
    try std.testing.expect(!model.sidebar_visible);
    try std.testing.expectEqual(@as(u64, 1), hidden.chrome_revision);
    try std.testing.expectEqual(Version{ .chrome = 1 }, model.version());
    try std.testing.expect(model.setSidebarVisible(false) == null);

    const shown = model.setSidebarVisible(true).?;

    try std.testing.expect(shown.visible);
    try std.testing.expect(model.sidebar_visible);
    try std.testing.expectEqual(@as(u64, 2), shown.chrome_revision);
    try std.testing.expectEqual(Version{ .chrome = 2 }, model.version());
}

test "configuration adoption commits generation sidebar and pane gaps once" {
    var model = ClientModel.initWithConfiguration(std.testing.allocator, true, 1);
    defer model.deinit();

    const changed = try model.applyConfiguration(.{
        .generation = 2,
        .sidebar_visible = false,
        .pane_gaps = false,
    });

    try std.testing.expectEqual(@as(u64, 2), changed.generation);
    try std.testing.expectEqual(@as(u64, 1), changed.configuration_revision);
    try std.testing.expect(!changed.sidebar.?.visible);
    try std.testing.expect(changed.pane_gaps_changed);
    try std.testing.expectEqual(@as(u64, 1), changed.panes_revision);
    try std.testing.expectEqual(@as(u64, 2), model.configuration_generation);
    try std.testing.expect(!model.sidebar_visible);
    try std.testing.expect(!model.pane_gaps);
    try std.testing.expectEqual(Version{
        .configuration = 1,
        .panes = 1,
        .chrome = 1,
    }, model.version());

    const semantic_noop = try model.applyConfiguration(.{
        .generation = 3,
        .sidebar_visible = false,
        .pane_gaps = false,
    });

    try std.testing.expect(semantic_noop.sidebar == null);
    try std.testing.expect(!semantic_noop.pane_gaps_changed);
    try std.testing.expectEqual(Version{
        .configuration = 2,
        .panes = 1,
        .chrome = 1,
    }, model.version());
}

test "configuration adoption rejects an old generation without partial state" {
    var model = ClientModel.initWithConfiguration(std.testing.allocator, true, 4);
    defer model.deinit();
    const version = model.version();

    try std.testing.expectError(error.StaleConfiguration, model.applyConfiguration(.{
        .generation = 4,
        .sidebar_visible = false,
        .pane_gaps = false,
    }));

    try std.testing.expectEqual(@as(u64, 4), model.configuration_generation);
    try std.testing.expect(model.sidebar_visible);
    try std.testing.expect(model.pane_gaps);
    try std.testing.expectEqualDeep(version, model.version());
}

test "client diagnostics publish only changed valid text" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();

    try std.testing.expect(model.diagnostic() == null);
    try std.testing.expectEqual(model_data.Change.changed, try model.setDiagnostic(
        "Lua failed: {s}",
        .{
            "boom",
        },
    ));
    try std.testing.expectEqualStrings("Lua failed: boom", model.diagnostic().?);
    try std.testing.expectEqual(Version{ .diagnostic = 1 }, model.version());
    try std.testing.expectEqual(model_data.Change.unchanged, try model.setDiagnostic(
        "Lua failed: {s}",
        .{
            "boom",
        },
    ));
    try std.testing.expectEqual(Version{ .diagnostic = 1 }, model.version());

    var invalid: model_data.Diagnostic = .{};
    invalid.buffer[0] = 0xff;
    invalid.len = 1;
    try std.testing.expectError(error.InvalidClientDiagnostic, model.replaceDiagnostic(invalid));
    invalid.len = invalid.buffer.len + 1;
    try std.testing.expectError(error.InvalidClientDiagnostic, model.replaceDiagnostic(invalid));
    try std.testing.expectEqualStrings("Lua failed: boom", model.diagnostic().?);

    try std.testing.expectEqual(model_data.Change.changed, model.clearDiagnostic());
    try std.testing.expect(model.diagnostic() == null);
    try std.testing.expectEqual(model_data.Change.unchanged, model.clearDiagnostic());
    try std.testing.expectEqual(Version{ .diagnostic = 2 }, model.version());
}

test "callback context is a value projection of committed client state" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();

    try std.testing.expectEqualDeep(model_data.CallbackContext{
        .sidebar_visible = true,
        .tab_count = 0,
        .active_tab_index = 0,
        .pane_count = 0,
        .focused_pane_id = 0,
    }, model.callbackContext());

    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(3) },
        .tab_id = @enumFromInt(5),
    };
    const pane_id: core.PaneId = @enumFromInt(7);
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = pane_id, .location = location, .size = .{ .cols = 20, .rows = 5 } });
    _ = model.toggleSidebar();

    try std.testing.expectEqualDeep(model_data.CallbackContext{
        .sidebar_visible = false,
        .tab_count = 1,
        .active_tab_index = 0,
        .pane_count = 1,
        .focused_pane_id = core.raw(pane_id),
    }, model.callbackContext());
}

test "plugin execution is single flight and completion matches its exact identity" {
    var model = ClientModel.initWithConfiguration(std.testing.allocator, true, 7);
    defer model.deinit();

    const first = (try model.beginPluginExecution()).?;

    try std.testing.expectEqual(@as(u64, 1), @intFromEnum(first.id));
    try std.testing.expectEqual(@as(u64, 7), first.configuration_generation);
    try std.testing.expectEqualDeep(first, model.plugins.pluginExecution().?);
    try std.testing.expect((try model.beginPluginExecution()) == null);
    try std.testing.expect(model.plugins.finishPluginExecution(@enumFromInt(99)) == null);
    try std.testing.expectEqualDeep(first, model.plugins.pluginExecution().?);
    try std.testing.expectEqualDeep(first, model.plugins.finishPluginExecution(first.id).?);
    try std.testing.expect(model.plugins.pluginExecution() == null);

    const second = (try model.beginPluginExecution()).?;

    try std.testing.expectEqual(@as(u64, 2), @intFromEnum(second.id));
    try std.testing.expectEqualDeep(Version{}, model.version());
}

test "plugin execution retains its launch generation across configuration reload" {
    var model = ClientModel.initWithConfiguration(std.testing.allocator, true, 3);
    defer model.deinit();
    const execution = (try model.beginPluginExecution()).?;

    _ = try model.applyConfiguration(.{
        .generation = 4,
        .sidebar_visible = true,
        .pane_gaps = true,
    });

    try std.testing.expectEqual(@as(u64, 3), model.plugins.pluginExecution().?.configuration_generation);
    try std.testing.expectEqualDeep(execution, model.plugins.finishPluginExecution(execution.id).?);
}

test "plugin execution identity exhaustion cannot publish a partial reservation" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();
    model.plugins.next_plugin_execution_id = std.math.maxInt(u64);

    const last = (try model.beginPluginExecution()).?;

    try std.testing.expectEqual(std.math.maxInt(u64), @intFromEnum(last.id));
    _ = model.plugins.finishPluginExecution(last.id);
    try std.testing.expectError(error.PluginExecutionIdExhausted, model.beginPluginExecution());
    try std.testing.expect(model.plugins.pluginExecution() == null);
}

test "clipboard capture is single flight and completion matches its exact identity" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();
    const target: model_data.AttachmentTarget = .{
        .pane_id = @enumFromInt(7),
        .pane_generation = 3,
    };

    const first = (try model.clipboard.reserve(target)).?;

    try std.testing.expectEqual(@as(u64, 1), @intFromEnum(first.id));
    try std.testing.expectEqualDeep(target, first.target);
    try std.testing.expectEqualDeep(first, model.clipboard.capture.?);
    try std.testing.expect((try model.clipboard.reserve(target)) == null);
    try std.testing.expect(model.clipboard.finish(@enumFromInt(99)) == null);
    try std.testing.expectEqualDeep(first, model.clipboard.capture.?);
    try std.testing.expectEqualDeep(first, model.clipboard.finish(first.id).?);
    try std.testing.expect(model.clipboard.capture == null);

    const second = (try model.clipboard.reserve(target)).?;

    try std.testing.expectEqual(@as(u64, 2), @intFromEnum(second.id));
    try std.testing.expect(!model.clipboard.cancel(.{
        .pane_id = target.pane_id,
        .pane_generation = target.pane_generation + 1,
    }));
    try std.testing.expect(model.clipboard.cancel(target));
    try std.testing.expect(model.clipboard.capture == null);
    try std.testing.expectEqualDeep(Version{}, model.version());
}

test "clipboard capture validation and identity exhaustion leave no reservation" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();

    try std.testing.expectError(error.InvalidAttachmentTarget, model.clipboard.reserve(.{
        .pane_id = .invalid,
        .pane_generation = 1,
    }));
    try std.testing.expect(model.clipboard.capture == null);

    model.clipboard.next_id = std.math.maxInt(u64);
    const last = (try model.clipboard.reserve(.{
        .pane_id = @enumFromInt(4),
        .pane_generation = 2,
    })).?;

    try std.testing.expectEqual(std.math.maxInt(u64), @intFromEnum(last.id));
    _ = model.clipboard.finish(last.id);
    try std.testing.expectError(
        error.ClipboardCaptureIdExhausted,
        model.clipboard.reserve(last.target),
    );
    try std.testing.expect(model.clipboard.capture == null);
}

test "host resize commits resolved geometry once" {
    const initial: core.TerminalSize = .{
        .cols = 80,
        .rows = 24,
        .cell_width_px = 10,
        .cell_height_px = 20,
    };
    var model = ClientModel.initWithState(std.testing.allocator, .{
        .pane_gaps = true,
        .host_size = initial,
        .host_capabilities = .{
            .cell_width_px = 10,
            .cell_height_px = 20,
        },
    });
    defer model.deinit();
    const resized: core.TerminalSize = .{
        .cols = 100,
        .rows = 30,
        .cell_width_px = 10,
        .cell_height_px = 20,
    };

    const commit = (try model.reconcileHost(.{
        .capabilities = model.host.host_capabilities,
        .size = resized,
    })).?.resize.?;

    try std.testing.expectEqualDeep(initial, commit.previous);
    try std.testing.expectEqualDeep(resized, commit.current);
    try std.testing.expect(commit.grid_changed);
    try std.testing.expect(!commit.cell_size_changed);
    try std.testing.expectEqual(@as(u64, 1), commit.host_revision);
    try std.testing.expectEqualDeep(resized, model.host.host_size);
    try std.testing.expectEqual(Version{ .host = 1 }, model.version());
    try std.testing.expect((try model.reconcileHost(.{
        .capabilities = model.host.host_capabilities,
        .size = resized,
    })) == null);
    try std.testing.expectEqual(Version{ .host = 1 }, model.version());
}

test "host resize rejects invalid and oversized grids without partial state" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();
    const size = model.host.host_size;
    const version = model.version();

    try std.testing.expectError(error.InvalidTerminalSize, model.reconcileHost(.{
        .capabilities = model.host.host_capabilities,
        .size = .{ .cols = 0, .rows = 24 },
    }));
    try std.testing.expectError(error.ScreenTooLarge, model.reconcileHost(.{
        .capabilities = model.host.host_capabilities,
        .size = .{
            .cols = std.math.maxInt(u16),
            .rows = std.math.maxInt(u16),
        },
    }));

    try std.testing.expectEqualDeep(size, model.host.host_size);
    try std.testing.expectEqualDeep(version, model.version());
}

test "presentation capabilities commit independently without probe policy" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();

    const graphics_commit = (try model.observeHostCapability(.{ .images = .supported })).?;
    try std.testing.expect(graphics_commit.resize == null);
    try std.testing.expectEqual(model_data.EnvironmentSupport.supported, model.host.host_capabilities.images);
    try std.testing.expectEqual(model_data.EnvironmentSupport.unknown, model.host.host_capabilities.pointer_pixels);

    _ = try model.observeHostCapability(.{ .pointer_pixels = .unsupported });
    const version = model.version();
    try std.testing.expect((try model.observeHostCapability(.{ .pointer_pixels = .unsupported })) == null);
    try std.testing.expectEqualDeep(version, model.version());
}

test "host pixel observations commit raw measurements and resolved geometry atomically" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();

    const window = (try model.observeHostCapability(.{ .window_pixels = .{
        .width = 800,
        .height = 480,
    } })).?;

    try std.testing.expectEqual(core.TerminalSize{
        .cols = 80,
        .rows = 24,
        .cell_width_px = 10,
        .cell_height_px = 20,
    }, model.host.host_size);
    try std.testing.expect(window.capabilities != null);
    try std.testing.expect(window.resize != null);
    try std.testing.expectEqual(Version{
        .host = 1,
        .host_capabilities = 1,
    }, model.version());

    const cell = (try model.observeHostCapability(.{ .cell_pixels = .{
        .width = 12,
        .height = 24,
    } })).?;
    try std.testing.expect(cell.resize != null);
    try std.testing.expectEqual(@as(u16, 12), model.host.host_size.cell_width_px);
    try std.testing.expectEqual(@as(u16, 24), model.host.host_size.cell_height_px);

    const later_window = (try model.observeHostCapability(.{ .window_pixels = .{
        .width = 1600,
        .height = 960,
    } })).?;
    try std.testing.expect(later_window.resize == null);
    try std.testing.expectEqual(@as(u16, 12), model.host.host_size.cell_width_px);
    try std.testing.expectEqual(@as(u16, 24), model.host.host_size.cell_height_px);
    try std.testing.expectEqual(Version{
        .host = 2,
        .host_capabilities = 3,
    }, model.version());
}

test "host reconciliation validates geometry before publishing capabilities" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();
    var capabilities = model.host.host_capabilities;
    capabilities.window_width_px = 1200;
    const size = model.host.host_size;
    const version = model.version();

    try std.testing.expectError(error.InconsistentHostGeometry, model.reconcileHost(.{
        .capabilities = capabilities,
        .size = size,
    }));
    try std.testing.expectError(error.ScreenTooLarge, model.reconcileHost(.{
        .capabilities = capabilities,
        .size = .{
            .cols = std.math.maxInt(u16),
            .rows = std.math.maxInt(u16),
        },
    }));

    try std.testing.expectEqualDeep(size, model.host.host_size);
    try std.testing.expectEqualDeep(model_data.HostCapabilities{}, model.host.host_capabilities);
    try std.testing.expectEqualDeep(version, model.version());
}

test "workspace list collapse advances only the chrome revision" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();

    try std.testing.expect(!model.workspace_list_collapsed);
    try std.testing.expect(model.setWorkspaceListCollapsed(false) == null);
    try std.testing.expectEqualDeep(Version{}, model.version());

    const collapsed = model.toggleWorkspaceList();

    try std.testing.expect(collapsed.collapsed);
    try std.testing.expect(model.workspace_list_collapsed);
    try std.testing.expectEqual(@as(u64, 1), collapsed.chrome_revision);
    try std.testing.expectEqual(Version{ .chrome = 1 }, model.version());
    try std.testing.expect(model.setWorkspaceListCollapsed(true) == null);

    const expanded = model.setWorkspaceListCollapsed(false).?;

    try std.testing.expect(!expanded.collapsed);
    try std.testing.expect(!model.workspace_list_collapsed);
    try std.testing.expectEqual(@as(u64, 2), expanded.chrome_revision);
    try std.testing.expectEqual(Version{ .chrome = 2 }, model.version());
}

test "workspace list reconciliation owns navigation state and one isolated revision" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();
    var first_name = [_]u8{ 't', 'e', 'l', 'a', 'r' };
    var first_path = [_]u8{ '/', 'w', '/', 't', 'e', 'l', 'a', 'r' };
    const entries = [_]EntryInput{
        .{ .workspace = @enumFromInt(1), .name = &first_name, .path = &first_path, .tab_count = 2 },
        .{ .workspace = @enumFromInt(2), .name = "api", .path = "/work/api", .tab_count = 1 },
    };

    const commit = (try model.reconcileWorkspaceList(.{
        .revision = 7,
        .entries = &entries,
    })).?;
    @memset(&first_name, 'x');
    @memset(&first_path, 'x');

    try std.testing.expectEqual(@as(u64, 7), commit.runtime_revision);
    try std.testing.expectEqual(@as(usize, 2), commit.count);
    try std.testing.expectEqual(@as(u64, 1), commit.workspace_list_revision);
    try std.testing.expectEqual(Version{ .workspace_list = 1 }, model.version());
    try std.testing.expectEqualStrings("telar", model.workspace_list_snapshot.nameAt(0));
    try std.testing.expectEqualStrings("/w/telar", model.workspace_list_snapshot.pathAt(0));
    try std.testing.expect(model.knowsWorkspace(@enumFromInt(1)));
    try std.testing.expect(!model.knowsWorkspace(@enumFromInt(9)));
    try std.testing.expectEqual(@as(core.WorkspaceId, @enumFromInt(2)), model.workspace_list_snapshot.workspaceAtPosition(1).?);
    try std.testing.expect(model.workspace_list_snapshot.workspaceAtPosition(2) == null);

    try std.testing.expect((try model.reconcileWorkspaceList(.{
        .revision = 6,
        .entries = &entries,
    })) == null);
    try std.testing.expectEqual(Version{ .workspace_list = 1 }, model.version());

    const duplicate = [_]EntryInput{
        .{ .workspace = @enumFromInt(3), .name = "one", .path = "/one", .tab_count = 1 },
        .{ .workspace = @enumFromInt(3), .name = "two", .path = "/two", .tab_count = 1 },
    };
    try std.testing.expectError(error.DuplicateWorkspace, model.reconcileWorkspaceList(.{
        .revision = 8,
        .entries = &duplicate,
    }));
    try std.testing.expectEqual(Version{ .workspace_list = 1 }, model.version());
    try std.testing.expectEqualStrings("telar", model.workspace_list_snapshot.nameAt(0));
}
