//! Client integration tests for renaming and telemetry.
const keyinput = @import("keyinput");

const data = @import("model");
const client_module = @import("telar-client");
const core = @import("telar-core");
const ClientHarness = @import("ClientHarness.zig");
const std = @import("std");
const fixtures = @import("fixtures.zig");

test "workspace rename separates prompt submission canonical commit and presentation" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before_prompt = client.model.version();
    const observed_before_prompt = client.presentation.observed;

    try std.testing.expect(client_module.name_prompt.openNamePrompt(&client.model, .rename_workspace));
    try std.testing.expect(client.model.name_prompt.active());
    try std.testing.expectEqualStrings("", client.model.name_prompt.currentConst().?.field.text());
    try fixtures.expectNonPromptVersionEqual(version_before_prompt, client.model.version());
    try std.testing.expect(client.model.version().prompt > version_before_prompt.prompt);
    try std.testing.expectEqualDeep(observed_before_prompt, client.presentation.observed);

    try harness.present();
    try std.testing.expectEqualDeep(client.model.version(), client.presentation.delivered.model);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presentation.prepared.model);

    const version_before_request = client.model.version();
    const observed_before_request = client.presentation.observed;
    try typeText(client, "mainx");
    try pressKey(client, .enter);

    try std.testing.expect(!data.copy_mode.isActive(&client.model));
    try std.testing.expect(!client.model.name_prompt.active());
    try std.testing.expectEqualStrings("", client.model.workspaceName());
    try fixtures.expectNonPromptVersionEqual(version_before_request, client.model.version());
    try std.testing.expect(client.model.version().prompt > version_before_request.prompt);
    try std.testing.expectEqualDeep(observed_before_request, client.presentation.observed);
    const version_after_request = client.model.version();
    try harness.settle();

    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .rename_workspace);
    try std.testing.expectEqualStrings("mainx", message.rename_workspace.name);
    try std.testing.expectEqualDeep(ClientHarness.bootstrap_location.workspace, message.rename_workspace.workspace);

    var payload: [512]u8 = undefined;
    const renamed = try core.encodeWorkspaceSnapshot(&payload, .{
        .request_id = message.rename_workspace.request_id,
        .workspace = message.rename_workspace.workspace,
        .name = message.rename_workspace.name,
        .tabs = &.{
            .{ .tab_id = ClientHarness.bootstrap_location.tab_id, .position = 0, .pane_count = 1, .label = "" },
        },
    });
    const observed_before_response = client.presentation.observed;
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(renamed));

    try std.testing.expectEqualStrings("mainx", client.model.workspaceName());
    try std.testing.expectEqual(version_before_request.workspace + 1, client.model.version().workspace);
    try std.testing.expectEqual(version_before_request.tabs, client.model.version().tabs);
    try std.testing.expectEqual(version_before_request.active_tab, client.model.version().active_tab);
    try std.testing.expectEqual(version_after_request.prompt, client.model.version().prompt);
    try std.testing.expectEqualDeep(observed_before_response, client.presentation.observed);

    try harness.present();
    try std.testing.expectEqualDeep(client.model.version(), client.presentation.delivered.model);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presentation.prepared.model);

    const version_before_noop = client.model.version();
    const observed_before_noop = client.presentation.observed;
    try client.model.request_lifecycle.tracker.add(@enumFromInt(90), .{
        .rename_workspace = ClientHarness.bootstrap_location.workspace,
    });
    const unchanged = try core.encodeWorkspaceSnapshot(&payload, .{
        .request_id = @enumFromInt(90),
        .workspace = ClientHarness.bootstrap_location.workspace,
        .name = "mainx",
        .tabs = &.{
            .{ .tab_id = ClientHarness.bootstrap_location.tab_id, .position = 0, .pane_count = 1, .label = "" },
        },
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(unchanged));
    try harness.present();

    try std.testing.expectEqualDeep(version_before_noop, client.model.version());
    try std.testing.expectEqualDeep(observed_before_noop, client.presentation.observed);
}

test "pending workspace operation keeps the rename prompt without sending" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    try client.model.request_lifecycle.tracker.add(@enumFromInt(90), .{
        .rename_workspace = ClientHarness.bootstrap_location.workspace,
    });
    const next_request_id = client.model.request_lifecycle.next_request_id;
    const version_before_request = client.model.version();

    try std.testing.expect(client_module.name_prompt.openNamePrompt(&client.model, .rename_workspace));
    try typeText(client, "x");
    try pressKey(client, .enter);

    try std.testing.expect(!data.copy_mode.isActive(&client.model));
    try std.testing.expect(client.model.name_prompt.active());
    try std.testing.expectEqual(next_request_id, client.model.request_lifecycle.next_request_id);
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
    try fixtures.expectNonPromptVersionEqual(version_before_request, client.model.version());
    try std.testing.expect(client.model.version().prompt > version_before_request.prompt);

    try pressKey(client, .escape);
    try std.testing.expect(!data.copy_mode.isActive(&client.model));
    try std.testing.expect(!client.model.name_prompt.active());
}

test "an unexpected tab rename is rejected without effects" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};
    const version_before = client.model.version();
    const observed_before = client.presentation.observed;
    const renamed: core.TabRenamed = .{
        .request_id = @enumFromInt(99),
        .location = ClientHarness.bootstrap_location,
        .label = "canonical",
    };

    try std.testing.expectError(error.UnexpectedTabRenamed, client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .tab_renamed = renamed,
        },
    ));

    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqualDeep(observed_before, client.presentation.observed);
    try std.testing.expectEqualStrings("shell", data.tab_label.text(&client.model, client.model.tabs.active));
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
}

test "tab rename consumes an incompatible continuation before rejection" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};
    const request_id: core.RequestId = @enumFromInt(90);
    const version_before = client.model.version();
    try client.model.request_lifecycle.tracker.add(request_id, .notification);
    const renamed: core.TabRenamed = .{
        .request_id = request_id,
        .location = ClientHarness.bootstrap_location,
        .label = "canonical",
    };

    try std.testing.expectError(error.UnexpectedTabRenamed, client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .tab_renamed = renamed,
        },
    ));
    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
    try std.testing.expectError(error.UnexpectedTabRenamed, client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .tab_renamed = renamed,
        },
    ));
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqualStrings("shell", data.tab_label.text(&client.model, client.model.tabs.active));
}

test "tab rename consumes a mismatched location before rejection" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};
    const request_id: core.RequestId = @enumFromInt(90);
    const version_before = client.model.version();
    try client.model.request_lifecycle.tracker.add(request_id, .{ .rename_tab = ClientHarness.bootstrap_location });
    const renamed: core.TabRenamed = .{
        .request_id = request_id,
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(9) },
            .tab_id = ClientHarness.bootstrap_location.tab_id,
        },
        .label = "canonical",
    };

    try std.testing.expectError(error.UnexpectedTabRenamed, client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .tab_renamed = renamed,
        },
    ));
    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqualStrings("shell", data.tab_label.text(&client.model, client.model.tabs.active));
}

test "tab rename consumes a canonical response rejected by the model" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};
    const request_id: core.RequestId = @enumFromInt(90);
    const missing: core.TabLocation = .{
        .workspace = ClientHarness.bootstrap_location.workspace,
        .tab_id = @enumFromInt(9),
    };
    const version_before = client.model.version();
    try client.model.request_lifecycle.tracker.add(request_id, .{ .rename_tab = missing });
    const renamed: core.TabRenamed = .{
        .request_id = request_id,
        .location = missing,
        .label = "canonical",
    };

    try std.testing.expectError(error.UnexpectedTabRenamed, client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .tab_renamed = renamed,
        },
    ));
    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
    try std.testing.expectError(error.UnexpectedTabRenamed, client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .tab_renamed = renamed,
        },
    ));
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqualStrings("shell", data.tab_label.text(&client.model, client.model.tabs.active));
}

test "tab rename separates prompt submission canonical commit and presentation" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};
    const version_before_request = client.model.version();
    const observed_before_request = client.presentation.observed;

    try std.testing.expect(client_module.name_prompt.openNamePrompt(
        &client.model,
        .{
            .rename_tab = ClientHarness.bootstrap_location.tab_id,
        },
    ));
    try std.testing.expect(data.key_routing.captures(client_module.key_routing.keyRoutingAuthority(client)));

    try typeText(client, "x");
    try pressKey(client, .enter);
    try std.testing.expect(!data.copy_mode.isActive(&client.model));
    try std.testing.expect(!client.model.name_prompt.active());
    try std.testing.expectEqualStrings("shell", data.tab_label.text(&client.model, client.model.tabs.active));
    try fixtures.expectNonPromptVersionEqual(version_before_request, client.model.version());
    try std.testing.expect(client.model.version().prompt > version_before_request.prompt);
    try std.testing.expectEqualDeep(observed_before_request, client.presentation.observed);
    const version_after_request = client.model.version();
    try harness.settle();

    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .rename_tab);
    try std.testing.expectEqualStrings("shellx", message.rename_tab.label);
    try std.testing.expectEqualDeep(ClientHarness.bootstrap_location, message.rename_tab.location);
    const continuation = client.model.request_lifecycle.tracker.take(message.rename_tab.request_id).?;
    try std.testing.expect(continuation == .rename_tab);
    try std.testing.expectEqualDeep(ClientHarness.bootstrap_location, continuation.rename_tab);
    try client.model.request_lifecycle.tracker.add(message.rename_tab.request_id, continuation);

    var payload: [256]u8 = undefined;
    const renamed = try core.encodeTabRenamed(&payload, .{
        .request_id = message.rename_tab.request_id,
        .location = message.rename_tab.location,
        .label = "canonical",
    });
    const observed_before_response = client.presentation.observed;
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(renamed));
    @memset(&payload, 'x');

    try std.testing.expectEqualStrings("canonical", data.tab_label.text(&client.model, client.model.tabs.active));
    try std.testing.expectEqual(version_before_request.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_request.active_tab, client.model.version().active_tab);
    try std.testing.expectEqual(version_after_request.prompt, client.model.version().prompt);
    try std.testing.expectEqualDeep(observed_before_response, client.presentation.observed);

    try harness.present();
    try std.testing.expectEqualDeep(client.model.version(), client.presentation.delivered.model);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presentation.prepared.model);

    const version_before_noop = client.model.version();
    const observed_before_noop = client.presentation.observed;
    try client.model.request_lifecycle.tracker.add(@enumFromInt(90), .{ .rename_tab = ClientHarness.bootstrap_location });
    const unchanged = try core.encodeTabRenamed(&payload, .{
        .request_id = @enumFromInt(90),
        .location = ClientHarness.bootstrap_location,
        .label = "canonical",
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(unchanged));
    try harness.present();

    try std.testing.expectEqualDeep(version_before_noop, client.model.version());
    try std.testing.expectEqualDeep(observed_before_noop, client.presentation.observed);
}

test "tab rename response must match the requested identity" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};

    try std.testing.expect(client_module.name_prompt.openNamePrompt(
        &client.model,
        .{
            .rename_tab = ClientHarness.bootstrap_location.tab_id,
        },
    ));
    try typeText(client, "x");
    try pressKey(client, .enter);
    const version_before_response = client.model.version();
    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&message_buffer);
    var response_buffer: [256]u8 = undefined;
    const response = try core.encodeTabRenamed(&response_buffer, .{
        .request_id = message.rename_tab.request_id,
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(9) },
            .tab_id = message.rename_tab.location.tab_id,
        },
        .label = "canonical",
    });

    try std.testing.expectError(
        error.UnexpectedTabRenamed,
        client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(response)),
    );

    try std.testing.expectEqualStrings("shell", data.tab_label.text(&client.model, client.model.tabs.active));
    try std.testing.expectEqualDeep(version_before_response, client.model.version());
    try std.testing.expect(!client.model.request_lifecycle.tracker.has(.tab_operation));
}

test "a failed tab rename preserves the label and notifies" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};

    try std.testing.expect(client_module.name_prompt.openNamePrompt(
        &client.model,
        .{
            .rename_tab = ClientHarness.bootstrap_location.tab_id,
        },
    ));
    try typeText(client, "x");
    try pressKey(client, .enter);
    const version_before_failure = client.model.version();
    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&message_buffer);
    var response_buffer: [256]u8 = undefined;
    const response = try core.encodeRequestFailed(&response_buffer, .{
        .request_id = message.rename_tab.request_id,
        .code = .tab_not_found,
        .message = "tab not found",
    });

    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(response));

    try std.testing.expectEqualStrings("shell", data.tab_label.text(&client.model, client.model.tabs.active));
    try fixtures.expectOnlyNotificationVersionChanged(version_before_failure, client.model.version());
    try std.testing.expect(!client.model.request_lifecycle.tracker.has(.tab_operation));
    try std.testing.expect(client.model.notification_scheduler.pending);
}

test "pending tab operation keeps the rename prompt without sending" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};
    try client.model.request_lifecycle.tracker.add(@enumFromInt(90), .{ .move_tab = ClientHarness.bootstrap_location });
    const next_request_id = client.model.request_lifecycle.next_request_id;
    const version_before_request = client.model.version();

    try std.testing.expect(client_module.name_prompt.openNamePrompt(
        &client.model,
        .{
            .rename_tab = ClientHarness.bootstrap_location.tab_id,
        },
    ));
    try typeText(client, "x");
    try pressKey(client, .enter);

    try std.testing.expect(!data.copy_mode.isActive(&client.model));
    try std.testing.expect(client.model.name_prompt.active());
    try std.testing.expectEqual(next_request_id, client.model.request_lifecycle.next_request_id);
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
    try fixtures.expectNonPromptVersionEqual(version_before_request, client.model.version());
    try std.testing.expect(client.model.version().prompt > version_before_request.prompt);

    try pressKey(client, .escape);
    try std.testing.expect(!data.copy_mode.isActive(&client.model));
    try std.testing.expect(!client.model.name_prompt.active());
}

test "a full outbox keeps the tab rename prompt and rolls back correlation" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};
    const version_before_request = client.model.version();
    while (client.model.to_runtime.hasCapacity()) {
        try client.model.to_runtime.push(.{ .detach_pane = .{ .pane_id = ClientHarness.bootstrap_pane } });
    }

    try std.testing.expect(client_module.name_prompt.openNamePrompt(
        &client.model,
        .{
            .rename_tab = ClientHarness.bootstrap_location.tab_id,
        },
    ));

    try typeText(client, "x");
    try std.testing.expectError(error.ClientOutboxFull, pressKey(client, .enter));

    try std.testing.expect(!data.copy_mode.isActive(&client.model));
    try std.testing.expect(client.model.name_prompt.active());
    try std.testing.expect(!client.model.request_lifecycle.tracker.has(.tab_operation));
    try std.testing.expectEqual(data.outbox_support.capacity, @as(usize, client.model.to_runtime.len));
    try std.testing.expectEqualStrings("shell", data.tab_label.text(&client.model, client.model.tabs.active));
    try fixtures.expectNonPromptVersionEqual(version_before_request, client.model.version());
    try std.testing.expect(client.model.version().prompt > version_before_request.prompt);
}

test "escaping the prompt editor closes model state without changing mode" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};

    _ = try client_module.actions.executeAction(client, .new_workspace, .binding);
    try std.testing.expect(client.model.name_prompt.active());
    try std.testing.expect(!data.copy_mode.isActive(&client.model));
    try pressKey(client, .escape);
    try std.testing.expect(!data.copy_mode.isActive(&client.model));
    try std.testing.expect(!client.model.name_prompt.active());
}

// Routes each character as one semantic key through key routing, as an
// adapter delivers typed text to the active prompt.
fn typeText(client: *client_module.Client, text: []const u8) !void {
    var characters = (try std.unicode.Utf8View.init(text)).iterator();
    while (characters.nextCodepointSlice()) |character| {
        try pressKey(client, .{ .char = keyinput.Char.init(character) });
    }
}

fn pressKey(client: *client_module.Client, code: keyinput.Key.Code) !void {
    _ = try client_module.key_routing.routeKeyInput(
        client,
        .{
            .key = .{
                .code = code,
            },
        },
    );
}
