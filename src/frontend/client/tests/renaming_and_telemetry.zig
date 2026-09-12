//! Client integration tests for renaming and telemetry.

const TerminalClient = @import("../TerminalClient.zig");
const host = TerminalClient.of;
const TestHarness = @import("TestHarness.zig");
const std = @import("std");
const name_prompts = @import("telar-client").controllers.name_prompts;
const support = @import("support.zig");
const presentation_lifecycle = @import("../presentation/presentation_lifecycle.zig");
const InputHandler = @import("../resources/InputHandler.zig");
const encodeWorkspaceSnapshot_module = @import("telar-core").encodeWorkspaceSnapshot;
const server_messages = @import("telar-client").server_messages;
const decodeServer_module = @import("telar-core").decodeServer;
const TabRenamedType = @import("telar-core").TabRenamed;
const tab_renames = @import("telar-client").controllers.tab_renames;
const RequestIdType = @import("telar-core").RequestId;
const TabLocationType = @import("telar-core").TabLocation;
const encodeTabRenamed_module = @import("telar-core").encodeTabRenamed;
const encodeRequestFailed_module = @import("telar-core").encodeRequestFailed;
const capacity_module = @import("telar-client").capacity;
const enabled_module = @import("telar-core").enabled;
const client_telemetry = @import("../resources/telemetry.zig");

test "workspace rename separates prompt submission canonical commit and presentation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before_prompt = client.model.version();
    const pending_updates_before_prompt = host(client).presenter.pending_updates;

    try std.testing.expect(name_prompts.beginWorkspaceRename(client));
    try std.testing.expect(client.model.name_prompt.active());
    try std.testing.expectEqualStrings("", client.model.name_prompt.currentConst().?.field.text());
    try support.expectNonPromptVersionEqual(version_before_prompt, client.model.version());
    try std.testing.expect(client.model.version().prompt > version_before_prompt.prompt);
    try std.testing.expectEqual(pending_updates_before_prompt, host(client).presenter.pending_updates);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates_before_prompt + 1, host(client).presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), host(client).presenter.presentation_state.prepared.model);

    const version_before_request = client.model.version();
    const pending_updates_before_request = host(client).presenter.pending_updates;
    var handler: InputHandler = .{ .client = client };
    try handler.forward("mainx\r");

    try std.testing.expect(!client.model.copyModeActive());
    try std.testing.expect(!client.model.name_prompt.active());
    try std.testing.expectEqualStrings("", client.model.workspace.workspaceName());
    try support.expectNonPromptVersionEqual(version_before_request, client.model.version());
    try std.testing.expect(client.model.version().prompt > version_before_request.prompt);
    try std.testing.expectEqual(pending_updates_before_request, host(client).presenter.pending_updates);
    const version_after_request = client.model.version();
    try harness.settle();

    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .rename_workspace);
    try std.testing.expectEqualStrings("mainx", message.rename_workspace.name);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location.workspace, message.rename_workspace.workspace);

    var payload: [512]u8 = undefined;
    const renamed = try encodeWorkspaceSnapshot_module(&payload, .{
        .request_id = message.rename_workspace.request_id,
        .workspace = message.rename_workspace.workspace,
        .name = message.rename_workspace.name,
        .tabs = &.{
            .{ .tab_id = TestHarness.bootstrap_location.tab_id, .position = 0, .pane_count = 1, .label = "main" },
        },
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(renamed));

    try std.testing.expectEqualStrings("mainx", client.model.workspace.workspaceName());
    try std.testing.expectEqual(version_before_request.workspace + 1, client.model.version().workspace);
    try std.testing.expectEqual(version_before_request.tabs, client.model.version().tabs);
    try std.testing.expectEqual(version_before_request.active_tab, client.model.version().active_tab);
    try std.testing.expectEqual(version_after_request.prompt, client.model.version().prompt);
    try std.testing.expectEqual(pending_updates_before_request, host(client).presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before_request + 1, host(client).presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), host(client).presenter.presentation_state.prepared.model);

    const version_before_noop = client.model.version();
    const pending_updates_before_noop = host(client).presenter.pending_updates;
    try client.request_lifecycle.tracker.add(@enumFromInt(90), .{
        .rename_workspace = TestHarness.bootstrap_location.workspace,
    });
    const unchanged = try encodeWorkspaceSnapshot_module(&payload, .{
        .request_id = @enumFromInt(90),
        .workspace = TestHarness.bootstrap_location.workspace,
        .name = "mainx",
        .tabs = &.{
            .{ .tab_id = TestHarness.bootstrap_location.tab_id, .position = 0, .pane_count = 1, .label = "main" },
        },
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(unchanged));
    try presentation_lifecycle.observe(client);

    try std.testing.expectEqualDeep(version_before_noop, client.model.version());
    try std.testing.expectEqual(pending_updates_before_noop, host(client).presenter.pending_updates);
}

test "pending workspace operation keeps the rename prompt without sending" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    try client.request_lifecycle.tracker.add(@enumFromInt(90), .{
        .rename_workspace = TestHarness.bootstrap_location.workspace,
    });
    const next_request_id = client.request_lifecycle.next_request_id;
    const version_before_request = client.model.version();

    try std.testing.expect(name_prompts.beginWorkspaceRename(client));
    var handler: InputHandler = .{ .client = client };
    try handler.forward("x\r");

    try std.testing.expect(!client.model.copyModeActive());
    try std.testing.expect(client.model.name_prompt.active());
    try std.testing.expectEqual(next_request_id, client.request_lifecycle.next_request_id);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try support.expectNonPromptVersionEqual(version_before_request, client.model.version());
    try std.testing.expect(client.model.version().prompt > version_before_request.prompt);

    try handler.forward("\x1b");
    try std.testing.expect(!client.model.copyModeActive());
    try std.testing.expect(!client.model.name_prompt.active());
}

test "an unexpected tab rename is rejected without effects" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const version_before = client.model.version();
    const pending_updates_before = host(client).presenter.pending_updates;
    const renamed: TabRenamedType = .{
        .request_id = @enumFromInt(99),
        .location = TestHarness.bootstrap_location,
        .label = "canonical",
    };

    try std.testing.expectError(error.UnexpectedTabRenamed, tab_renames.apply(client, renamed));

    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, host(client).presenter.pending_updates);
    try std.testing.expectEqualStrings("main", client.model.workspace.activeConst().?.labelSlice());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "tab rename consumes an incompatible continuation before rejection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const request_id: RequestIdType = @enumFromInt(90);
    const version_before = client.model.version();
    try client.request_lifecycle.tracker.add(request_id, .notification);
    const renamed: TabRenamedType = .{
        .request_id = request_id,
        .location = TestHarness.bootstrap_location,
        .label = "canonical",
    };

    try std.testing.expectError(error.UnexpectedTabRenamed, tab_renames.apply(client, renamed));
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectError(error.UnexpectedTabRenamed, tab_renames.apply(client, renamed));
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqualStrings("main", client.model.workspace.activeConst().?.labelSlice());
}

test "tab rename consumes a mismatched location before rejection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const request_id: RequestIdType = @enumFromInt(90);
    const version_before = client.model.version();
    try client.request_lifecycle.tracker.add(request_id, .{ .rename_tab = TestHarness.bootstrap_location });
    const renamed: TabRenamedType = .{
        .request_id = request_id,
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(9) },
            .tab_id = TestHarness.bootstrap_location.tab_id,
        },
        .label = "canonical",
    };

    try std.testing.expectError(error.UnexpectedTabRenamed, tab_renames.apply(client, renamed));
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqualStrings("main", client.model.workspace.activeConst().?.labelSlice());
}

test "tab rename consumes a canonical response rejected by the model" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const request_id: RequestIdType = @enumFromInt(90);
    const missing: TabLocationType = .{
        .workspace = TestHarness.bootstrap_location.workspace,
        .tab_id = @enumFromInt(9),
    };
    const version_before = client.model.version();
    try client.request_lifecycle.tracker.add(request_id, .{ .rename_tab = missing });
    const renamed: TabRenamedType = .{
        .request_id = request_id,
        .location = missing,
        .label = "canonical",
    };

    try std.testing.expectError(error.UnexpectedTabRenamed, tab_renames.apply(client, renamed));
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectError(error.UnexpectedTabRenamed, tab_renames.apply(client, renamed));
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqualStrings("main", client.model.workspace.activeConst().?.labelSlice());
}

test "tab rename separates prompt submission canonical commit and presentation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const version_before_request = client.model.version();
    const pending_updates_before_request = host(client).presenter.pending_updates;

    try std.testing.expect(name_prompts.beginTabRename(client, TestHarness.bootstrap_location.tab_id));
    var handler: InputHandler = .{ .client = client };
    try std.testing.expect(handler.capturesKeys());

    try handler.forward("x");
    try handler.forward("\r");
    try std.testing.expect(!client.model.copyModeActive());
    try std.testing.expect(!client.model.name_prompt.active());
    try std.testing.expectEqualStrings("main", client.model.workspace.activeConst().?.labelSlice());
    try support.expectNonPromptVersionEqual(version_before_request, client.model.version());
    try std.testing.expect(client.model.version().prompt > version_before_request.prompt);
    try std.testing.expectEqual(pending_updates_before_request, host(client).presenter.pending_updates);
    const version_after_request = client.model.version();
    try harness.settle();

    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .rename_tab);
    try std.testing.expectEqualStrings("mainx", message.rename_tab.label);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, message.rename_tab.location);
    const continuation = client.request_lifecycle.tracker.take(message.rename_tab.request_id).?;
    try std.testing.expect(continuation == .rename_tab);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, continuation.rename_tab);
    try client.request_lifecycle.tracker.add(message.rename_tab.request_id, continuation);

    var payload: [256]u8 = undefined;
    const renamed = try encodeTabRenamed_module(&payload, .{
        .request_id = message.rename_tab.request_id,
        .location = message.rename_tab.location,
        .label = "canonical",
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(renamed));
    @memset(&payload, 'x');

    try std.testing.expectEqualStrings("canonical", client.model.workspace.activeConst().?.labelSlice());
    try std.testing.expectEqual(version_before_request.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_request.active_tab, client.model.version().active_tab);
    try std.testing.expectEqual(version_after_request.prompt, client.model.version().prompt);
    try std.testing.expectEqual(pending_updates_before_request, host(client).presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before_request + 1, host(client).presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), host(client).presenter.presentation_state.prepared.model);

    const version_before_noop = client.model.version();
    const pending_updates_before_noop = host(client).presenter.pending_updates;
    try client.request_lifecycle.tracker.add(@enumFromInt(90), .{ .rename_tab = TestHarness.bootstrap_location });
    const unchanged = try encodeTabRenamed_module(&payload, .{
        .request_id = @enumFromInt(90),
        .location = TestHarness.bootstrap_location,
        .label = "canonical",
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(unchanged));
    try presentation_lifecycle.observe(client);

    try std.testing.expectEqualDeep(version_before_noop, client.model.version());
    try std.testing.expectEqual(pending_updates_before_noop, host(client).presenter.pending_updates);
}

test "tab rename response must match the requested identity" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};

    try std.testing.expect(name_prompts.beginTabRename(client, TestHarness.bootstrap_location.tab_id));
    var handler: InputHandler = .{ .client = client };
    try handler.forward("x\r");
    const version_before_response = client.model.version();
    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&message_buffer);
    var response_buffer: [256]u8 = undefined;
    const response = try encodeTabRenamed_module(&response_buffer, .{
        .request_id = message.rename_tab.request_id,
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(9) },
            .tab_id = message.rename_tab.location.tab_id,
        },
        .label = "canonical",
    });

    try std.testing.expectError(
        error.UnexpectedTabRenamed,
        server_messages.handleServerMessage(client, try decodeServer_module(response)),
    );

    try std.testing.expectEqualStrings("main", client.model.workspace.activeConst().?.labelSlice());
    try std.testing.expectEqualDeep(version_before_response, client.model.version());
    try std.testing.expect(!client.request_lifecycle.tracker.has(.tab_operation));
}

test "a failed tab rename preserves the label and notifies" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};

    try std.testing.expect(name_prompts.beginTabRename(client, TestHarness.bootstrap_location.tab_id));
    var handler: InputHandler = .{ .client = client };
    try handler.forward("x\r");
    const version_before_failure = client.model.version();
    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&message_buffer);
    var response_buffer: [256]u8 = undefined;
    const response = try encodeRequestFailed_module(&response_buffer, .{
        .request_id = message.rename_tab.request_id,
        .code = .tab_not_found,
        .message = "tab not found",
    });

    _ = try server_messages.handleServerMessage(client, try decodeServer_module(response));

    try std.testing.expectEqualStrings("main", client.model.workspace.activeConst().?.labelSlice());
    try support.expectOnlyNotificationVersionChanged(version_before_failure, client.model.version());
    try std.testing.expect(!client.request_lifecycle.tracker.has(.tab_operation));
    try std.testing.expect(client.notification_scheduler.pending);
}

test "pending tab operation keeps the rename prompt without sending" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    try client.request_lifecycle.tracker.add(@enumFromInt(90), .{ .move_tab = TestHarness.bootstrap_location });
    const next_request_id = client.request_lifecycle.next_request_id;
    const version_before_request = client.model.version();

    try std.testing.expect(name_prompts.beginTabRename(client, TestHarness.bootstrap_location.tab_id));
    var handler: InputHandler = .{ .client = client };
    try handler.forward("x\r");

    try std.testing.expect(!client.model.copyModeActive());
    try std.testing.expect(client.model.name_prompt.active());
    try std.testing.expectEqual(next_request_id, client.request_lifecycle.next_request_id);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try support.expectNonPromptVersionEqual(version_before_request, client.model.version());
    try std.testing.expect(client.model.version().prompt > version_before_request.prompt);

    try handler.forward("\x1b");
    try std.testing.expect(!client.model.copyModeActive());
    try std.testing.expect(!client.model.name_prompt.active());
}

test "a full outbox keeps the tab rename prompt and rolls back correlation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const version_before_request = client.model.version();
    while (client.runtime_transport.outbox.hasCapacity()) {
        try client.runtime_transport.outbox.push(.{ .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane } });
    }

    try std.testing.expect(name_prompts.beginTabRename(client, TestHarness.bootstrap_location.tab_id));
    var handler: InputHandler = .{ .client = client };

    try std.testing.expectError(error.ClientOutboxFull, handler.forward("x\r"));

    try std.testing.expect(!client.model.copyModeActive());
    try std.testing.expect(client.model.name_prompt.active());
    try std.testing.expect(!client.request_lifecycle.tracker.has(.tab_operation));
    try std.testing.expectEqual(capacity_module, @as(usize, client.runtime_transport.outbox.len));
    try std.testing.expectEqualStrings("main", client.model.workspace.activeConst().?.labelSlice());
    try support.expectNonPromptVersionEqual(version_before_request, client.model.version());
    try std.testing.expect(client.model.version().prompt > version_before_request.prompt);
}

test "escaping the prompt editor closes model state without changing mode" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};

    try std.testing.expect(name_prompts.beginWorkspaceCreate(client));
    try std.testing.expect(client.model.name_prompt.active());
    try std.testing.expect(!client.model.copyModeActive());
    var handler: InputHandler = .{ .client = client };
    try handler.forward("\x1b");
    try std.testing.expect(!client.model.copyModeActive());
    try std.testing.expect(!client.model.name_prompt.active());
}

test "client telemetry writes one snapshot without mutating semantic state" {
    if (!enabled_module) {
        return;
    }

    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const model_version = client.model.version();
    const presented_version = host(client).presenter.presentation_state.prepared.model;
    const file = try temp.dir.createFile(io, "client.log", .{});
    client.telemetry.sink.deinit(io);
    client.telemetry.sink = .{ .file = file };
    client.telemetry.enabled = true;

    client_telemetry.handleTick(client, {}, .{ .observation_allocs = 7 });

    try std.testing.expect(client.telemetry.write_pending);
    const line_end = (std.mem.indexOfScalar(u8, &client.telemetry.buffer, '\n') orelse
        return error.TelemetryLineMissing) + 1;
    const line = client.telemetry.buffer[0..line_end];
    try std.testing.expect(std.mem.indexOf(u8, line, "\"role\":\"client\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"active_tab\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"observation_allocs\":7") != null);

    switch (try host(client).select.await()) {
        .telemetry_written => |result| client_telemetry.handleWritten(client, result),
        else => return error.UnexpectedEvent,
    }
    try std.testing.expect(!client.telemetry.write_pending);
    try std.testing.expect(client.telemetry.enabled);
    try std.testing.expect(client.telemetry.sink.available());
    try std.testing.expectEqualDeep(model_version, client.model.version());
    try std.testing.expectEqualDeep(presented_version, host(client).presenter.presentation_state.prepared.model);

    client_telemetry.handleTick(client, error.TickFailed, .{});
    try std.testing.expect(!client.telemetry.enabled);
    try std.testing.expect(!client.telemetry.sink.available());
}
