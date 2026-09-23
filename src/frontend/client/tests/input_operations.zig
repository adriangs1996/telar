//! Exercises direct operations with real client state and the runtime outbox.
const data = @import("model");

const std = @import("std");
const api = @import("telar-client");
const core = @import("telar-core");
const TestHarness = @import("TestHarness.zig");
const TerminalClient = @import("../TerminalClient.zig");
const support = @import("support.zig");

fn fillOutbox(client: *api.AttachedClient) !void {
    while (client.model.to_runtime.hasCapacity()) {
        try client.model.to_runtime.push(.{ .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane } });
    }
}

test "key press rolls back its physical lease when runtime delivery fails" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    try fillOutbox(client);
    var key = try data.chord.parseKey("x");
    key.physical = .{ .value = 41 };

    try std.testing.expectError(error.ClientOutboxFull, client.routeKeyInput(
        .{
            .key = key,
        },
    ));
    try std.testing.expectEqual(@as(usize, 0), client.model.input_leases.count());
    try std.testing.expect(client.model.input_leases.owner(key.physical.?) == null);
}

test "physical key repeat and release keep their pane after focus and prompt changes" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    const tab = client.model.tabs.active;
    const other: core.PaneId = @enumFromInt(11);
    try data.pane_split.split(&client.model, tab, .{ .existing_pane = TestHarness.bootstrap_pane, .new_pane = other, .location = TestHarness.bootstrap_location, .axis = .horizontal, .area = terminal.view.workbench() });
    try std.testing.expect(client.model.tabs.layout[tab].focusPane(TestHarness.bootstrap_pane));
    var key = try data.chord.parseKey("x");
    key.physical = .{ .value = 41 };
    try std.testing.expect((try client.routeKeyInput(
        .{
            .key = key,
        },
    )).delivered);
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const press = try harness.nextClientMessage(&buffer);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, press.pane_input.pane_id);

    try std.testing.expect(client.model.tabs.layout[tab].focusPane(other));
    client.model.name_prompt.begin(.goto_picker);
    key.phase = .repeat;
    try std.testing.expect((try client.routeKeyInput(
        .{
            .key = key,
        },
    )).delivered);
    try harness.settle();
    const repeated = try harness.nextClientMessage(&buffer);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, repeated.pane_input.pane_id);
    try std.testing.expectEqualStrings("x", repeated.pane_input.bytes);
    try std.testing.expectEqualStrings("", client.model.name_prompt.currentConst().?.field.text());

    key.phase = .release;
    const released = try client.routeKeyInput(
        .{
            .key = key,
        },
    );
    try std.testing.expectEqual(.pane, released.owner);
    try std.testing.expectEqual(@as(usize, 0), client.model.input_leases.count());
    const duplicate = try client.routeKeyInput(
        .{
            .key = key,
        },
    );
    try std.testing.expectEqual(.ignored, duplicate.owner);
}

test "physical lease saturation rejects input before mutation or transport" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    var identity: u32 = 1;
    while (client.model.input_leases.acquire(.{ .value = identity }, .ignored)) {
        identity += 1;
    }
    const version = client.model.version();
    const overflows = client.telemetry.metrics.key_lease_overflows;
    var key = try data.chord.parseKey("x");
    key.physical = .{ .value = identity + 1 };

    const outcome = try client.routeKeyInput(
        .{
            .key = key,
        },
    );

    try std.testing.expectEqual(.ignored, outcome.owner);
    try std.testing.expect(outcome.lease_overflow);
    try std.testing.expectEqual(overflows + 1, client.telemetry.metrics.key_lease_overflows);
    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
    try std.testing.expect(!client.model.to_runtime.inFlight());
}

test "failed opening paste marker rolls back the captured session" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.panes.find(TestHarness.bootstrap_pane).?.input_modes.bracketed_paste = true;
    try fillOutbox(client);

    try std.testing.expectError(error.ClientOutboxFull, client.startPanePaste());
    try std.testing.expect(!client.model.panePasteActive());
}

test "failed closing paste marker releases the session without repeating it" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.panes.find(TestHarness.bootstrap_pane).?.input_modes.bracketed_paste = true;
    try std.testing.expectEqual(.applied, try client.startPanePaste());
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const opening = try harness.nextClientMessage(&buffer);
    try std.testing.expectEqualStrings("\x1b[200~", opening.pane_input.bytes);
    try fillOutbox(client);

    try std.testing.expectError(error.ClientOutboxFull, client.finishPanePaste());
    try std.testing.expect(!client.model.panePasteActive());
    try std.testing.expectEqual(.ignored, try client.finishPanePaste());
}

test "retired paste target cannot redirect its remaining content" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    try std.testing.expectEqual(.applied, try client.startPanePaste());
    client.model.panes.find(TestHarness.bootstrap_pane).?.attached = false;

    try std.testing.expectEqual(.unavailable, try client.appendPanePaste("private text"));
    _ = try client.finishPanePaste();
    try std.testing.expect(!client.model.panePasteActive());
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
    try std.testing.expect(!client.model.to_runtime.inFlight());
}

test "obsolete clipboard completion frees its image without consuming a newer capture" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    const target = try support.installTestingAttachmentTarget(client, 1);
    const old = (try client.model.clipboard.reserve(target)).?;
    _ = client.model.clipboard.finish(old.id);
    const current = (try client.model.clipboard.reserve(target)).?;
    const image = try support.testingClipboardCapture(client, old, "private image");

    try client.completeClipboardCapture(
        .{
            .execution_id = old.id,
            .result = image,
        },
    );

    try std.testing.expectEqual(current.id, client.model.clipboard.capture.?.id);
    try std.testing.expect(client.model.clipboard.orphan == null);
    try std.testing.expectEqual(@as(u8, 0), terminal.view.kittyAttachments().snapshot().len);
}

test "blocked name submission keeps the exact prompt open until cancellation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    try std.testing.expect(client.openNamePrompt(.rename_active_tab));
    _ = try client.inputPrompt(
        .{
            .command = .{
                .insert = "renamed",
            },
        },
    );
    try fillOutbox(client);

    try std.testing.expectError(error.ClientOutboxFull, client.inputPrompt(
        .{
            .command = .submit,
        },
    ));
    try std.testing.expect(client.model.name_prompt.active());
    try std.testing.expectEqualStrings("shellrenamed", client.model.name_prompt.currentConst().?.field.text());
    try std.testing.expectEqual(.cancelled, try client.inputPrompt(
        .{
            .command = .cancel,
        },
    ));
    try std.testing.expect(!client.model.name_prompt.active());
}
