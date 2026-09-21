//! Exercises direct operations with real client state and the runtime outbox.

const std = @import("std");
const api = @import("telar-client");
const core = @import("telar-core");
const TestHarness = @import("TestHarness.zig");
const TerminalClient = @import("../TerminalClient.zig");
const support = @import("support.zig");
const key_routing = api.operations.key_routing;
const pane_pastes = api.operations.pane_pastes;
const clipboard_images = api.operations.clipboard_images;
const name_prompts = api.operations.name_prompts;

fn fillOutbox(client: *api.AttachedClient) !void {
    while (client.runtime_transport.outbox.hasCapacity()) {
        try client.runtime_transport.outbox.push(.{ .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane } });
    }
}

test "key press rolls back its physical lease when runtime delivery fails" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    try fillOutbox(client);
    var key = try api.parseKey("x");
    key.physical = .{ .value = 41 };

    try std.testing.expectError(error.ClientOutboxFull, key_routing.apply(client, .{ .key = key }));
    try std.testing.expectEqual(@as(usize, 0), client.input_leases.count());
    try std.testing.expect(client.input_leases.owner(key.physical.?) == null);
}

test "physical key repeat and release keep their pane after focus and prompt changes" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const tab = client.model.activeTabModel().?;
    const other: core.PaneId = @enumFromInt(11);
    try tab.split(.{ .existing_pane = TestHarness.bootstrap_pane, .new_pane = other, .location = TestHarness.bootstrap_location, .axis = .horizontal, .area = TerminalClient.of(client).view.workbench() });
    try std.testing.expect(tab.focusPane(TestHarness.bootstrap_pane));
    var key = try api.parseKey("x");
    key.physical = .{ .value = 41 };
    try std.testing.expect((try key_routing.apply(client, .{ .key = key })).delivered);
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const press = try harness.nextClientMessage(&buffer);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, press.pane_input.pane_id);

    try std.testing.expect(tab.focusPane(other));
    client.model.name_prompt.begin(.goto_picker);
    key.phase = .repeat;
    try std.testing.expect((try key_routing.apply(client, .{ .key = key })).delivered);
    try harness.settle();
    const repeated = try harness.nextClientMessage(&buffer);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, repeated.pane_input.pane_id);
    try std.testing.expectEqualStrings("x", repeated.pane_input.bytes);
    try std.testing.expectEqualStrings("", client.model.name_prompt.currentConst().?.field.text());

    key.phase = .release;
    const released = try key_routing.apply(client, .{ .key = key });
    try std.testing.expectEqual(.pane, released.owner);
    try std.testing.expectEqual(@as(usize, 0), client.input_leases.count());
    const duplicate = try key_routing.apply(client, .{ .key = key });
    try std.testing.expectEqual(.ignored, duplicate.owner);
}

test "physical lease saturation rejects input before mutation or transport" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    var identity: u32 = 1;
    while (client.input_leases.acquire(.{ .value = identity }, .ignored)) {
        identity += 1;
    }
    const version = client.model.version();
    const overflows = client.telemetry.metrics.key_lease_overflows;
    var key = try api.parseKey("x");
    key.physical = .{ .value = identity + 1 };

    const outcome = try key_routing.apply(client, .{ .key = key });

    try std.testing.expectEqual(.ignored, outcome.owner);
    try std.testing.expect(outcome.lease_overflow);
    try std.testing.expectEqual(overflows + 1, client.telemetry.metrics.key_lease_overflows);
    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try std.testing.expect(!client.runtime_transport.outbox.inFlight());
}

test "failed opening paste marker rolls back the captured session" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.workspace.findPane(TestHarness.bootstrap_pane).?.input_modes.bracketed_paste = true;
    try fillOutbox(client);

    try std.testing.expectError(error.ClientOutboxFull, pane_pastes.start(client));
    try std.testing.expect(!client.model.panePasteActive());
}

test "failed closing paste marker releases the session without repeating it" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.workspace.findPane(TestHarness.bootstrap_pane).?.input_modes.bracketed_paste = true;
    try std.testing.expectEqual(.applied, try pane_pastes.start(client));
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const opening = try harness.nextClientMessage(&buffer);
    try std.testing.expectEqualStrings("\x1b[200~", opening.pane_input.bytes);
    try fillOutbox(client);

    try std.testing.expectError(error.ClientOutboxFull, pane_pastes.finish(client));
    try std.testing.expect(!client.model.panePasteActive());
    try std.testing.expectEqual(.ignored, try pane_pastes.finish(client));
}

test "retired paste target cannot redirect its remaining content" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    try std.testing.expectEqual(.applied, try pane_pastes.start(client));
    client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached = false;

    try std.testing.expectEqual(.unavailable, try pane_pastes.content(client, "private text"));
    _ = try pane_pastes.finish(client);
    try std.testing.expect(!client.model.panePasteActive());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try std.testing.expect(!client.runtime_transport.outbox.inFlight());
}

test "obsolete clipboard completion frees its image without consuming a newer capture" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const target = try support.installTestingAttachmentTarget(client, 1);
    const old = (try client.model.beginClipboardCapture(target)).?;
    _ = client.model.finishClipboardCapture(old.id);
    const current = (try client.model.beginClipboardCapture(target)).?;
    const image = try support.testingClipboardCapture(client, old, "private image");

    try clipboard_images.complete(client, .{ .execution_id = old.id, .result = image });

    try std.testing.expectEqual(current.id, client.model.clipboardCapture().?.id);
    try std.testing.expect(client.clipboard_capture_resources.orphan == null);
    try std.testing.expectEqual(@as(u8, 0), TerminalClient.of(client).view.kittyAttachments().snapshot().len);
}

test "blocked name submission keeps the exact prompt open until cancellation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    try std.testing.expect(name_prompts.beginActiveTabRename(client));
    _ = try name_prompts.handleInput(client, .{ .command = .{ .insert = "renamed" } });
    try fillOutbox(client);

    try std.testing.expectError(error.ClientOutboxFull, name_prompts.handleInput(client, .{ .command = .submit }));
    try std.testing.expect(client.model.name_prompt.active());
    try std.testing.expectEqualStrings("shellrenamed", client.model.name_prompt.currentConst().?.field.text());
    try std.testing.expectEqual(.cancelled, try name_prompts.handleInput(client, .{ .command = .cancel }));
    try std.testing.expect(!client.model.name_prompt.active());
}
