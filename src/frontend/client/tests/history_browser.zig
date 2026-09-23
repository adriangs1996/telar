//! History flow proof through host input, runtime messages and the real client outbox.

const data = @import("model");
const core = @import("telar-core");
const TestHarness = @import("TestHarness.zig");
const std = @import("std");
const client_module = @import("telar-client");

const entry: core.HistoryEntry = .{ .id = 20, .pane_id = TestHarness.bootstrap_pane, .started_at_ms = 1000, .duration_ns = 1000000, .exit_code = 0, .status = .completed, .command = "zig build", .cwd = "/work", .workspace_path = "/work" };

test "history input preserves search through inspection and pages past the first reply" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    _ = try client_module.actions.executeAction(client, .history_palette, .binding);
    try std.testing.expect(client.model.name_prompt.active());
    try harness.settle();
    var buffer: [8192]u8 = undefined;
    const query = (try harness.nextClientMessage(&buffer)).query_history;
    try std.testing.expectEqual(@as(u16, 100), query.limit);
    try std.testing.expect(!query.distinct);

    const results = try core.encodeHistoryResults(&buffer, .{ .request_id = query.request_id, .entries = &.{entry}, .snapshot_id = 20, .has_more = true });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(results));
    _ = try client_module.name_prompt.inputPrompt(
        client,
        .{
            .key = .{
                .code = .{
                    .char = data.Char.init("o"),
                },
                .mods = .{
                    .ctrl = true,
                },
            },
        },
    );
    try std.testing.expect(client.model.name_prompt.currentConst().?.inspecting());
    try harness.settle();
    const read = (try harness.nextClientMessage(&buffer)).read_history_output;
    try std.testing.expectEqual(entry.id, read.id);
    const output = try core.encodeHistoryOutput(&buffer, .{ .request_id = read.request_id, .id = read.id, .content = "done", .observed_bytes = 4, .truncated = false });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(output));
    try std.testing.expectEqualStrings("done", client.model.history_palette.outputSlice());

    _ = try client_module.name_prompt.inputPrompt(
        client,
        .{
            .key = .{
                .code = .page_down,
            },
        },
    );
    try std.testing.expectEqual(@as(u32, 0), client.model.name_prompt.currentConst().?.detailScroll());

    _ = try client_module.name_prompt.inputPrompt(
        client,
        .{
            .key = .{
                .code = .escape,
            },
        },
    );
    try std.testing.expect(!client.model.name_prompt.currentConst().?.inspecting());
    try std.testing.expectEqualStrings("", client.model.name_prompt.currentConst().?.field.text());
    _ = try client_module.name_prompt.inputPrompt(
        client,
        .{
            .key = .{
                .code = .page_up,
            },
        },
    );
    try harness.settle();
    const next = (try harness.nextClientMessage(&buffer)).query_history;
    try std.testing.expectEqual(@as(u32, 1), next.offset);
    try std.testing.expectEqual(@as(u64, 20), next.snapshot_id);
    try std.testing.expect(!client_module.history_palette.canSubmitHistory(client, 0));

    const old = try core.encodeHistoryResults(&buffer, .{ .request_id = query.request_id, .entries = &.{entry} });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(old));
    try std.testing.expect(client.model.history_palette.phase == .loading);
    const failure: core.RequestFailed = .{ .request_id = next.request_id, .code = .resource_limit, .message = "Query busy" };
    _ = try client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .request_failed = failure,
        },
    );
    try std.testing.expect(client.model.history_palette.phase == .failed);
    try std.testing.expectEqualStrings("Query busy", client.model.history_palette.errorSlice());
}

test "history scope labels follow the effective runtime query" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    _ = try client_module.actions.executeAction(client, .history_palette, .binding);
    try std.testing.expect(client.model.name_prompt.active());
    try harness.settle();
    var buffer: [8192]u8 = undefined;
    _ = try harness.nextClientMessage(&buffer);

    _ = try client_module.name_prompt.inputPrompt(
        client,
        .{
            .key = .{
                .code = .tab,
            },
        },
    );
    try harness.settle();
    const workspace_query = (try harness.nextClientMessage(&buffer)).query_history;
    try std.testing.expect(workspace_query.scope == .global);
    try std.testing.expect(client.model.history_palette.effective_scope == .global);
    try std.testing.expect(client.model.name_prompt.currentConst().?.scope() == .workspace);

    _ = try client_module.name_prompt.inputPrompt(
        client,
        .{
            .key = .{
                .code = .tab,
            },
        },
    );
    try harness.settle();
    _ = try harness.nextClientMessage(&buffer);
    try std.testing.expect(client.model.name_prompt.currentConst().?.scope() == .cwd);

    _ = try client_module.name_prompt.inputPrompt(
        client,
        .{
            .key = .{
                .code = .tab,
            },
        },
    );
    try harness.settle();
    const query = (try harness.nextClientMessage(&buffer)).query_history;
    try std.testing.expect(query.scope == .pane);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, query.pane_id);
    try std.testing.expect(client.model.name_prompt.currentConst().?.scope() == .pane);
}

test "history submission sends a complete command longer than its preview" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    _ = try client_module.actions.executeAction(client, .history_palette, .binding);
    try std.testing.expect(client.model.name_prompt.active());
    try harness.settle();
    var buffer: [16384]u8 = undefined;
    const query = (try harness.nextClientMessage(&buffer)).query_history;
    const command = "x" ** 9000;
    var long_entry = entry;
    long_entry.command = command;
    const results = try core.encodeHistoryResults(&buffer, .{ .request_id = query.request_id, .entries = &.{long_entry} });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(results));
    client.model.config.history_enter_runs = false;
    _ = try client_module.name_prompt.inputPrompt(
        client,
        .{
            .key = .{
                .code = .enter,
            },
        },
    );
    try std.testing.expect(!client.model.name_prompt.active());
    var receiver = try std.Io.concurrent(std.testing.io, receiveCommand, .{ &harness, command });
    defer _ = receiver.cancel(std.testing.io) catch 0;
    try harness.settle();
    try std.testing.expectEqual(command.len, try receiver.await(std.testing.io));
}

fn receiveCommand(harness: *TestHarness, command: []const u8) !usize {
    var buffer: [16384]u8 = undefined;
    var received: usize = 0;
    while (received < command.len) {
        const message = try harness.nextClientMessage(&buffer);
        if (message != .pane_input) {
            continue;
        }

        try std.testing.expectEqualStrings(command[received..][0..message.pane_input.bytes.len], message.pane_input.bytes);
        received += message.pane_input.bytes.len;
    }

    return received;
}
