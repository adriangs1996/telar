const std = @import("std");
const core = @import("telar-core");
const Model = @import("../../model/Model.zig");
const AgentThreadHandler = @import("AgentThreadHandler.zig");
const Command = @import("../../model/name_prompt.zig").Command;
const AgentOperation = @import("../../connection/AgentOperation.zig");
const Outbox = @import("../../connection/Outbox.zig");
const HistoryHandler = @import("AgentHistoryHandler.zig");
const HistoryOperation = @import("../../connection/AgentHistoryOperation.zig");

const pane_id: core.PaneId = @enumFromInt(1);
const location: core.TabLocation = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(1) };

fn bootstrap(model: *Model) !void {
    try model.workspace.bootstrap(.{ .pane_id = pane_id, .location = location, .size = .{ .cols = 40, .rows = 10 } });
    const handler: AgentThreadHandler = .{ .model = model };
    try std.testing.expect(handler.identify(.{
        .request_id = @enumFromInt(1),
        .pane_id = pane_id,
        .location = location,
        .created = true,
        .kind = .agent,
        .pane_generation = 9,
    }));
}

fn readySnapshot(storage: []u8, revision: u64) !core.AgentThreadSnapshotView {
    var snapshot: core.AgentThreadSnapshot = .{
        .pane_id = pane_id,
        .pane_generation = 9,
        .revision = revision,
        .status = .ready,
        .item_count = 1,
        .text_len = 5,
        .options = try fixtureOptions(),
        .model_count = 1,
    };
    snapshot.model_storage[0] = .{
        .id = "fake-model".* ++ [_]u8{0} ** 118,
        .id_len = 10,
        .label = "Fake model".* ++ [_]u8{0} ** 118,
        .label_len = 10,
        .effort_count = 2,
        .default_effort = try core.AgentEffort.init("low"),
    };
    snapshot.model_storage[0].effort_storage[0] = try core.AgentEffort.init("low");
    snapshot.model_storage[0].effort_storage[1] = try core.AgentEffort.init("high");
    snapshot.item_storage[0] = .{ .identity = 1, .role = .assistant, .status = .completed, .text_len = 5, .complete = true };
    @memcpy(snapshot.text_storage[0..5], "Ready");
    const bytes = try core.encodeAgentThreadSnapshot(storage, &snapshot);
    return (try core.decodeServer(bytes)).agent_thread_snapshot;
}

fn fixtureOptions() !core.AgentOptions {
    var options: core.AgentOptions = .{ .effort = try core.AgentEffort.init("low") };
    try options.setModel("fake-model");
    return options;
}

test "created agent tabs immediately expose the attached composer and preserve workspace" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    try model.workspace.bootstrap(.{ .pane_id = pane_id, .location = location, .size = .{ .cols = 40, .rows = 10 } });
    const agent_id: core.PaneId = @enumFromInt(2);
    const created = try model.createTab(.{
        .created = .{
            .location = .{ .workspace = location.workspace, .tab_id = @enumFromInt(2) },
            .position = 1,
            .label = "Codex",
            .root_pane_id = agent_id,
            .kind = .agent,
            .pane_generation = 7,
        },
        .size = .{ .cols = 40, .rows = 10 },
    });
    try std.testing.expectEqualDeep(location.workspace, created.created.workspace);
    try std.testing.expectEqual(@as(usize, 2), model.workspace.count);
    try std.testing.expectEqual(agent_id, model.activeTabModelConst().?.layout.focused().?);
    try std.testing.expectEqual(core.PaneSurface.thread, model.activeTabModelConst().?.layout.surface(agent_id));
    try std.testing.expectEqual(@as(u64, 7), model.agentPane(agent_id).?.pane_generation);
    try std.testing.expect(model.agentPane(pane_id) == null);
    try std.testing.expect(model.editAgentComposer(agent_id, .{ .insert = "hello" }));
}

test "agent conversation survives receive reuse and rejects stale generations and revisions" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    try bootstrap(&model);
    const handler: AgentThreadHandler = .{ .model = &model };
    var bytes: [4096]u8 = undefined;
    const snapshot = try readySnapshot(&bytes, 1);
    try std.testing.expect(try handler.apply(snapshot));
    const revision = model.version().panes;
    try std.testing.expect(!try handler.apply(snapshot));
    try std.testing.expectEqual(revision, model.version().panes);
    @memset(&bytes, 0);
    const retained = model.agentPane(pane_id).?.agent_thread.?;
    try std.testing.expectEqualStrings("Ready", retained.items()[0].text(retained));

    var stale = try readySnapshot(&bytes, 2);
    stale.pane_generation = 8;
    try std.testing.expect(!try handler.apply(stale));
    try std.testing.expectEqual(@as(u64, 1), retained.revision);
    try std.testing.expect(model.planPaneInput(.focused) == null);
    try std.testing.expect(model.planPaneInput(.{ .key_lease = pane_id }) == null);
    try std.testing.expectEqual(core.PaneSurface.thread, model.togglePaneSurface().?);

    _ = model.departWorkspace();
    try std.testing.expect(!try handler.apply(try readySnapshot(&bytes, 3)));
}

test "independent clients retain activity identities and child status across snapshot replacement" {
    const first = try std.testing.allocator.create(Model);
    defer std.testing.allocator.destroy(first);
    first.* = Model.init(std.testing.allocator, true);
    defer first.deinit();
    try bootstrap(first);
    const second = try std.testing.allocator.create(Model);
    defer std.testing.allocator.destroy(second);
    second.* = Model.init(std.testing.allocator, true);
    defer second.deinit();
    try bootstrap(second);
    const first_handler: AgentThreadHandler = .{ .model = first };
    const second_handler: AgentThreadHandler = .{ .model = second };
    var bytes: [4096]u8 = undefined;
    var snapshot: core.AgentThreadSnapshot = undefined;
    try (try readySnapshot(&bytes, 1)).copyTo(&snapshot);
    snapshot.item_count = 2;
    snapshot.metadata_len = 13;
    @memcpy(snapshot.metadata_storage[0..13], "Inspectworker");
    snapshot.item_storage[0] = .{ .identity = 9, .turn_identity = 1, .role = .tool, .kind = .dispatch, .status = .completed, .complete = true, .title_len = 7 };
    snapshot.item_storage[1] = .{ .identity = 10, .turn_identity = 1, .parent_identity = 9, .role = .tool, .kind = .subagent, .status = .running, .reference_offset = 7, .reference_len = 6 };
    var view = (try core.decodeServer(try core.encodeAgentThreadSnapshot(&bytes, &snapshot))).agent_thread_snapshot;
    try std.testing.expect(try first_handler.apply(view));
    try std.testing.expect(try second_handler.apply(view));
    @memset(&bytes, 0);
    const first_thread = first.agentPane(pane_id).?.agent_thread.?;
    const second_thread = second.agentPane(pane_id).?.agent_thread.?;
    try std.testing.expectEqualStrings("worker", first_thread.findItem(10).?.reference(first_thread));
    try std.testing.expectEqual(core.agent_thread.ItemStatus.running, second_thread.findItem(10).?.status);
    try std.testing.expectEqual(@as(u64, 9), second_thread.findItem(10).?.parent_identity);

    _ = first.departWorkspace();
    snapshot.revision = 2;
    snapshot.item_storage[1].status = .completed;
    snapshot.item_storage[1].complete = true;
    view = (try core.decodeServer(try core.encodeAgentThreadSnapshot(&bytes, &snapshot))).agent_thread_snapshot;
    try std.testing.expect(!try first_handler.apply(view));
    try std.testing.expect(try second_handler.apply(view));
    @memset(&bytes, 0);
    try std.testing.expectEqual(core.agent_thread.ItemStatus.completed, second_thread.findItem(10).?.status);
    try std.testing.expectEqualStrings("Inspect", second_thread.findItem(9).?.title(second_thread));

    try bootstrap(first);
    view = (try core.decodeServer(try core.encodeAgentThreadSnapshot(&bytes, &snapshot))).agent_thread_snapshot;
    try std.testing.expect(try first_handler.apply(view));
    try std.testing.expectEqualDeep(second_thread.items(), first.agentPane(pane_id).?.agent_thread.?.items());
}

test "agent prompt acknowledgements preserve later edits and replacement attachments" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    try bootstrap(&model);
    const handler: AgentThreadHandler = .{ .model = &model };
    var bytes: [4096]u8 = undefined;
    _ = try handler.apply(try readySnapshot(&bytes, 1));
    try std.testing.expect(handler.prompt(pane_id) == null);
    try std.testing.expect(handler.edit(pane_id, Command{ .insert = "Fix the tests\nKeep the API" }));
    const prompt = handler.prompt(pane_id).?;
    const operation: AgentOperation = .{
        .pane_id = pane_id,
        .pane_generation = prompt.pane_generation,
        .attachment_generation = prompt.attachment_generation,
        .location = location,
        .composer_content_revision = prompt.composer_content_revision,
    };
    try std.testing.expect(handler.edit(pane_id, .{ .insert = " stable" }));
    try std.testing.expect(!handler.complete(operation));
    try std.testing.expectEqualStrings("Fix the tests\nKeep the API stable", model.agentPane(pane_id).?.composerSlice());

    var current = operation;
    current.composer_content_revision = model.agentPane(pane_id).?.composer_content_revision;
    current.attachment_generation += 1;
    try std.testing.expect(!handler.complete(current));
    current.attachment_generation = prompt.attachment_generation;
    try std.testing.expect(handler.complete(current));
    try std.testing.expectEqualStrings("", model.agentPane(pane_id).?.composerSlice());
}

test "composer editing is atomic at UTF-8 and capacity boundaries" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    try bootstrap(&model);
    const handler: AgentThreadHandler = .{ .model = &model };
    try std.testing.expect(handler.edit(pane_id, .{ .insert = "café\n" }));
    const revision = model.agentPane(pane_id).?.composer_revision;
    try std.testing.expect(!handler.edit(pane_id, .{ .replace_range = .{ .range = .{ 4, 5 }, .text = "x" } }));
    try std.testing.expect(!handler.edit(pane_id, .{ .insert = "\xff" }));
    try std.testing.expect(!handler.edit(pane_id, .{ .insert = "bad\x00prompt" }));
    try std.testing.expect(!handler.edit(pane_id, .{ .replace_range = .{ .range = .{ 0, 5 }, .text = "bad\x00prompt" } }));
    try std.testing.expect(!handler.edit(pane_id, .{ .insert = "x" ** 4096 }));
    try std.testing.expectEqual(revision, model.agentPane(pane_id).?.composer_revision);
    try std.testing.expectEqualStrings("café\n", model.agentPane(pane_id).?.composerSlice());
    try std.testing.expect(handler.edit(pane_id, .backspace));
    try std.testing.expect(handler.edit(pane_id, .backspace));
    try std.testing.expectEqualStrings("caf", model.agentPane(pane_id).?.composerSlice());
}

test "prompt acknowledgement clears unchanged content after cursor or selection changes" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    try bootstrap(&model);
    const handler: AgentThreadHandler = .{ .model = &model };
    var bytes: [4096]u8 = undefined;
    _ = try handler.apply(try readySnapshot(&bytes, 1));
    try std.testing.expect(handler.edit(pane_id, .{ .insert = "Fix the tests" }));
    const prompt = handler.prompt(pane_id).?;
    const editor_revision = model.agentPane(pane_id).?.composer_revision;

    try std.testing.expect(handler.edit(pane_id, .{ .move_left = false }));
    try std.testing.expect(handler.edit(pane_id, .select_all));
    try std.testing.expect(handler.edit(pane_id, .{ .replace_range = .{ .range = .{ 0, 13 }, .text = "Fix the tests" } }));
    const pane = model.agentPane(pane_id).?;
    try std.testing.expect(pane.composer_revision > editor_revision);
    try std.testing.expectEqual(prompt.composer_content_revision, pane.composer_content_revision);
    try std.testing.expect(handler.complete(.{
        .pane_id = pane_id,
        .pane_generation = prompt.pane_generation,
        .attachment_generation = prompt.attachment_generation,
        .location = location,
        .composer_content_revision = prompt.composer_content_revision,
    }));
    try std.testing.expectEqualStrings("", model.agentPane(pane_id).?.composerSlice());
}

test "queued prompts own their text and serialize agent identity" {
    var outbox: Outbox = .{};
    try std.testing.expectError(error.InvalidAgentPrompt, outbox.pushAgentPrompt(.{
        .request_id = @enumFromInt(6),
        .pane_id = pane_id,
        .pane_generation = 9,
        .text = "bad\x00prompt",
    }));
    try std.testing.expectEqual(@as(usize, 0), outbox.snapshot().depth);
    var draft = [_]u8{ 'f', 'i', 'x' };
    try outbox.pushAgentPrompt(.{
        .request_id = @enumFromInt(7),
        .pane_id = pane_id,
        .pane_generation = 9,
        .text = &draft,
        .options = try fixtureOptions(),
    });
    @memset(&draft, 'x');
    var bytes: [8192]u8 = undefined;
    const encoded = (try outbox.beginSend(&bytes)).?;
    const decoded = try core.decodeClient(encoded);
    try std.testing.expectEqualStrings("fix", decoded.agent_prompt.text);
    try std.testing.expectEqual(@as(u64, 9), decoded.agent_prompt.pane_generation);
    try std.testing.expectEqualStrings("fake-model", decoded.agent_prompt.options.modelSlice());
    try std.testing.expectEqualStrings("low", decoded.agent_prompt.options.effort.idSlice());
    try std.testing.expectEqual(core.AgentAccess.workspace, decoded.agent_prompt.options.access);
    try std.testing.expect(@sizeOf(@import("../../connection/OwnedAgentPrompt.zig")) < 512);
    try outbox.finishSend({});
}

test "agent draft settings use the catalog and survive streaming without changing catalog identity" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    try bootstrap(&model);
    const handler: AgentThreadHandler = .{ .model = &model };
    var bytes: [4096]u8 = undefined;
    _ = try handler.apply(try readySnapshot(&bytes, 1));
    const pane = model.agentPane(pane_id).?;
    const catalog = pane.catalog_revision;
    const revision = pane.options_revision;
    try std.testing.expect(!handler.select(pane_id, .{ .model = "unavailable" }));
    try std.testing.expect(!handler.select(pane_id, .{ .effort = try core.AgentEffort.init("ultra") }));
    try std.testing.expectEqual(revision, pane.options_revision);
    try std.testing.expect(handler.select(pane_id, .{ .effort = try core.AgentEffort.init("high") }));
    try std.testing.expect(!handler.select(pane_id, .{ .model = "fake-model" }));
    try std.testing.expect(handler.select(pane_id, .{ .access = .read_only }));
    _ = try handler.apply(try readySnapshot(&bytes, 2));
    try std.testing.expectEqual(catalog, pane.catalog_revision);
    try std.testing.expectEqualStrings("high", pane.agentOptions().effort.idSlice());
    try std.testing.expectEqual(core.AgentAccess.read_only, pane.agentOptions().access);
    _ = handler.edit(pane_id, .{ .insert = "hello" });
    const prompt = handler.prompt(pane_id).?;
    try std.testing.expectEqual(core.AgentAccess.read_only, prompt.options.access);
    try std.testing.expectEqualStrings("high", prompt.options.effort.idSlice());
}

fn historyModel() !*Model {
    const model = try std.testing.allocator.create(Model);
    errdefer std.testing.allocator.destroy(model);
    model.* = Model.init(std.testing.allocator, true);
    errdefer model.deinit();
    try bootstrap(model);
    var bytes: [4096]u8 = undefined;
    _ = try model.applyAgentThread(try readySnapshot(&bytes, 1));
    const snapshot = model.agentPane(pane_id).?.agent_thread.?;
    snapshot.truncated = true;
    snapshot.metadata_len = 10;
    @memcpy(snapshot.metadata_storage[0..10], "liveTurn-1");
    snapshot.item_storage[0].source_len = 4;
    snapshot.item_storage[0].source_turn_offset = 4;
    snapshot.item_storage[0].source_turn_len = 6;
    return model;
}

fn historyOperation(model: *Model, generation: u64) HistoryOperation {
    const pane = model.agentPane(pane_id).?;
    return .{ .owner = .{ .pane_id = pane_id, .pane_generation = pane.pane_generation, .attachment_generation = pane.attachment_generation, .location = pane.location }, .view_generation = generation };
}

fn historyResponse(buffer: []u8, generation: u64) !core.AgentHistoryPageView {
    const page = try std.testing.allocator.create(core.AgentHistoryPage);
    defer std.testing.allocator.destroy(page);
    page.* = .{ .request_id = @enumFromInt(100), .view_generation = generation, .snapshot = .{ .pane_id = pane_id, .pane_generation = 9, .revision = 77, .item_count = 1, .text_len = 7, .metadata_len = 3 }, .before = try core.AgentHistoryCursor.init("older-cursor"), .after = try core.AgentHistoryCursor.init("newer-cursor"), .has_before = true, .has_after = true };
    page.snapshot.item_storage[0] = .{ .role = .assistant, .identity = 700, .status = .completed, .complete = true, .text_len = 7, .source_len = 3 };
    @memcpy(page.snapshot.text_storage[0..7], "Earlier");
    @memcpy(page.snapshot.metadata_storage[0..3], "old");
    return (try core.decodeServer(try core.encodeAgentHistoryPage(buffer, page))).agent_history_page;
}

test "folded history scanning is bounded and preserves its seam across retries" {
    const model = try historyModel();
    defer std.testing.allocator.destroy(model);
    defer model.deinit();
    const handler: HistoryHandler = .{ .model = model };
    _ = handler.navigate(pane_id, .older);
    const initial = (try handler.begin(pane_id)).?;
    var buffer: [4096]u8 = undefined;
    _ = try handler.apply(historyOperation(model, initial.view_generation), try historyResponse(&buffer, initial.view_generation));
    const window = model.agentPane(pane_id).?.agent_history.?;
    const answer = window.pages[1].snapshot.items()[0].identity;
    const page = try std.testing.allocator.create(core.AgentHistoryPage);
    defer std.testing.allocator.destroy(page);
    page.* = window.pages[0];
    for (0..@import("../../panes/AgentHistoryWindow.zig").max_scan_pages) |index| {
        try std.testing.expect(handler.skipFolded(pane_id));
        const query = (try handler.begin(pane_id)).?;
        try std.testing.expect(!handler.skipFolded(pane_id));
        var cursor_buffer: [32]u8 = undefined;
        page.before = try core.AgentHistoryCursor.init(try std.fmt.bufPrint(&cursor_buffer, "older-{d}", .{index}));
        page.view_generation = query.view_generation;
        try std.testing.expect(window.apply(page));
        try std.testing.expectEqual(answer, window.pages[1].snapshot.items()[0].identity);
    }

    try std.testing.expect(!handler.skipFolded(pane_id));
    try std.testing.expect(model.agentPane(pane_id).?.history_intent == null);
    try std.testing.expect(handler.navigate(pane_id, .older));
    const failed = (try handler.begin(pane_id)).?;
    try std.testing.expect(window.preserve_seam);
    try std.testing.expect(handler.failed(historyOperation(model, failed.view_generation), "Unavailable"));
    try std.testing.expect(!handler.skipFolded(pane_id));
    try std.testing.expect(handler.navigate(pane_id, .older));
    const retry = (try handler.begin(pane_id)).?;
    page.before = try core.AgentHistoryCursor.init("retry");
    page.view_generation = retry.view_generation;
    try std.testing.expect(window.apply(page));
    try std.testing.expectEqual(answer, window.pages[1].snapshot.items()[0].identity);
    try std.testing.expect(handler.skipFolded(pane_id));
    const repeated = (try handler.begin(pane_id)).?;
    page.view_generation = repeated.view_generation;
    try std.testing.expect(window.apply(page));
    try std.testing.expect(window.failed);
    try std.testing.expect(!handler.skipFolded(pane_id));
    try std.testing.expectEqual(answer, window.pages[1].snapshot.items()[0].identity);
}

test "expanding work or reversing cancels a pending invisible page" {
    const model = try historyModel();
    defer std.testing.allocator.destroy(model);
    defer model.deinit();
    const handler: HistoryHandler = .{ .model = model };
    _ = handler.navigate(pane_id, .older);
    const initial = (try handler.begin(pane_id)).?;
    var buffer: [4096]u8 = undefined;
    _ = try handler.apply(historyOperation(model, initial.view_generation), try historyResponse(&buffer, initial.view_generation));
    const pane = model.agentPane(pane_id).?;
    const window = pane.agent_history.?;
    try std.testing.expect(handler.skipFolded(pane_id));
    const pending = (try handler.begin(pane_id)).?;
    handler.revealWork(pane_id);
    try std.testing.expect(window.pending == null and pane.history_intent == null);
    try std.testing.expect(!window.preserve_seam);
    try std.testing.expect(!try handler.apply(historyOperation(model, pending.view_generation), try historyResponse(&buffer, pending.view_generation)));
    try std.testing.expect(handler.navigate(pane_id, .older));
    const reverse = (try handler.begin(pane_id)).?;
    handler.reverse(pane_id, .newer);
    try std.testing.expect(!handler.skipFolded(pane_id));
    try std.testing.expect(!try handler.apply(historyOperation(model, reverse.view_generation), try historyResponse(&buffer, reverse.view_generation)));
    try std.testing.expectEqual(.newer, window.direction);
}

test "history navigation freezes the live seam and owns pages after receive reuse" {
    const model = try historyModel();
    defer std.testing.allocator.destroy(model);
    defer model.deinit();
    const handler: HistoryHandler = .{ .model = model };
    try std.testing.expect(handler.navigate(pane_id, .older));
    try std.testing.expect(model.agentPane(pane_id).?.agent_history == null);
    const query = (try handler.begin(pane_id)).?;
    try std.testing.expectEqualStrings("live", query.anchor);
    try std.testing.expectEqualStrings("Turn-1", query.anchor_turn);
    const pane = model.workspace.findPane(pane_id).?;
    const live = pane.agent_thread.?;
    @memcpy(live.text_storage[0..5], "Later");
    live.revision += 1;
    const frozen = &pane.agent_history.?.pages[0].snapshot;
    try std.testing.expectEqualStrings("Ready", frozen.items()[0].text(frozen));
    var buffer: [4096]u8 = undefined;
    try std.testing.expect(try handler.apply(historyOperation(model, query.view_generation), try historyResponse(&buffer, query.view_generation)));
    @memset(&buffer, 0);
    const window = pane.agent_history.?;
    try std.testing.expectEqual(@as(u8, 2), window.count);
    try std.testing.expectEqualStrings("Earlier", window.pages[0].snapshot.items()[0].text(&window.pages[0].snapshot));
    try std.testing.expectEqualStrings("Ready", window.pages[1].snapshot.items()[0].text(&window.pages[1].snapshot));
    try std.testing.expectEqualStrings("Later", live.items()[0].text(live));
    try std.testing.expectEqualStrings("older-cursor", window.cursor(.older));
    try std.testing.expect(!window.has(.newer));
    try std.testing.expect(handler.navigate(pane_id, .newer));
    try std.testing.expect(try handler.begin(pane_id) == null);
    try std.testing.expect(pane.agent_history == null);
    try std.testing.expectEqual(@as(u32, 0), pane.transcript_scroll);
}

test "history direction reversal rejects stale completion and preserves the next intent" {
    const model = try historyModel();
    defer std.testing.allocator.destroy(model);
    defer model.deinit();
    const handler: HistoryHandler = .{ .model = model };
    _ = handler.navigate(pane_id, .older);
    const query = (try handler.begin(pane_id)).?;
    const operation = historyOperation(model, query.view_generation);
    try std.testing.expect(!handler.navigate(pane_id, .older));
    try std.testing.expect(handler.navigate(pane_id, .newer));
    var buffer: [4096]u8 = undefined;
    try std.testing.expect(!try handler.apply(operation, try historyResponse(&buffer, query.view_generation)));
    try std.testing.expectEqual(core.agent_history.Direction.newer, model.agentPane(pane_id).?.history_intent.?);
    try std.testing.expect(!handler.failed(operation, "Old failure"));
    try std.testing.expect(try handler.begin(pane_id) == null);
    _ = handler.navigate(pane_id, .older);
    const replacement = (try handler.begin(pane_id)).?;
    var stale = historyOperation(model, replacement.view_generation);
    stale.owner.attachment_generation += 1;
    try std.testing.expect(!try handler.apply(stale, try historyResponse(&buffer, replacement.view_generation)));
    try std.testing.expect(handler.failed(historyOperation(model, replacement.view_generation), "Provider does not support history"));
    const window = model.agentPane(pane_id).?.agent_history.?;
    try std.testing.expectEqualStrings("Provider does not support history", window.failureMessage());
    try std.testing.expect(try handler.begin(pane_id) == null);
    try std.testing.expect(handler.navigate(pane_id, .older));
    try std.testing.expect((try handler.begin(pane_id)) != null);
    try std.testing.expect(!window.failed);
}

test "history entry requests the tail when the live item lost its suffix" {
    const model = try historyModel();
    defer std.testing.allocator.destroy(model);
    defer model.deinit();
    const live = model.agentPane(pane_id).?.agent_thread.?;
    live.item_storage[0].fragment_end = false;
    const handler: HistoryHandler = .{ .model = model };
    _ = handler.navigate(pane_id, .older);
    const query = (try handler.begin(pane_id)).?;
    try std.testing.expectEqualStrings("", query.anchor);
    var buffer: [4096]u8 = undefined;
    try std.testing.expect(try handler.apply(historyOperation(model, query.view_generation), try historyResponse(&buffer, query.view_generation)));
    const window = model.agentPane(pane_id).?.agent_history.?;
    try std.testing.expectEqual(@as(u8, 1), window.count);
    try std.testing.expect(!window.replace_seam);
    try std.testing.expectEqual(@as(u64, 700), window.pages[0].snapshot.items()[0].identity);
}

test "history input does not allocate and failed admission keeps the live conversation" {
    const model = try historyModel();
    defer std.testing.allocator.destroy(model);
    defer model.deinit();
    const pane = model.workspace.findPane(pane_id).?;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    pane.gpa = failing.allocator();
    defer pane.gpa = std.testing.allocator;
    const handler: HistoryHandler = .{ .model = model };
    try std.testing.expect(handler.navigate(pane_id, .older));
    try std.testing.expectEqual(@as(usize, 0), failing.allocated_bytes);
    try std.testing.expectError(error.OutOfMemory, handler.begin(pane_id));
    try std.testing.expect(pane.history_intent == null);
    try std.testing.expect(pane.agent_history == null);
    try std.testing.expectEqualStrings("Ready", pane.agent_thread.?.items()[0].text(pane.agent_thread.?));
}

test "queued agent history cursors own reused input without inflating message metadata" {
    var outbox: Outbox = .{};
    var cursor = "provider-cursor".*;
    var anchor = "provider-item".*;
    var anchor_turn = "provider-turn".*;
    try outbox.pushAgentHistory(.{ .request_id = @enumFromInt(19), .pane_id = pane_id, .pane_generation = 9, .view_generation = 11, .cursor = &cursor, .direction = .newer });
    try outbox.pushAgentHistory(.{ .request_id = @enumFromInt(20), .pane_id = pane_id, .pane_generation = 9, .view_generation = 12, .anchor = &anchor, .anchor_turn = &anchor_turn });
    @memset(&cursor, 0);
    @memset(&anchor, 0);
    @memset(&anchor_turn, 0);
    var bytes: [4096]u8 = undefined;
    const request = (try core.decodeClient((try outbox.beginSend(&bytes)).?)).query_agent_history;
    try std.testing.expectEqualStrings("provider-cursor", request.cursor);
    try std.testing.expectEqualStrings("", request.anchor);
    try std.testing.expectEqualStrings("", request.anchor_turn);
    try std.testing.expectEqual(@as(u64, 11), request.view_generation);
    try std.testing.expectEqual(core.agent_history.Direction.newer, request.direction);
    try outbox.finishSend({});
    const initial = (try core.decodeClient((try outbox.beginSend(&bytes)).?)).query_agent_history;
    try std.testing.expectEqualStrings("provider-item", initial.anchor);
    try std.testing.expectEqualStrings("provider-turn", initial.anchor_turn);
    try std.testing.expectEqualStrings("", initial.cursor);
    try std.testing.expect(@sizeOf(@import("../../connection/outbox_support.zig").Message) < 512);
}

test "hidden history completions update their window without invalidating the visible tab" {
    const model = try historyModel();
    defer std.testing.allocator.destroy(model);
    defer model.deinit();
    const handler: HistoryHandler = .{ .model = model };
    _ = handler.navigate(pane_id, .older);
    const query = (try handler.begin(pane_id)).?;
    const operation = historyOperation(model, query.view_generation);
    _ = try model.createTab(.{ .created = .{ .location = .{ .workspace = location.workspace, .tab_id = @enumFromInt(2) }, .position = 1, .label = "Terminal", .root_pane_id = @enumFromInt(2) }, .size = .{ .cols = 40, .rows = 10 } });
    const revision = model.panes_revision;
    var buffer: [4096]u8 = undefined;
    try std.testing.expect(try handler.apply(operation, try historyResponse(&buffer, query.view_generation)));
    try std.testing.expectEqual(revision, model.panes_revision);
    const hidden = model.workspace.findPane(pane_id).?;
    try std.testing.expectEqual(@as(u8, 2), hidden.agent_history.?.count);
    _ = handler.navigate(pane_id, .older);
    const next = (try handler.begin(pane_id)).?;
    var next_operation = operation;
    next_operation.view_generation = next.view_generation;
    try std.testing.expect(handler.failed(next_operation, "Hidden failure"));
    handler.retired();
    try std.testing.expectEqual(revision, model.panes_revision);
    try std.testing.expectEqualStrings("Hidden failure", hidden.agent_history.?.failureMessage());
}

test "uncompleted live items query the persisted tail without discarding the live bridge" {
    const model = try historyModel();
    defer std.testing.allocator.destroy(model);
    defer model.deinit();
    const live = model.agentPane(pane_id).?.agent_thread.?;
    live.item_storage[0].complete = false;
    live.item_storage[0].status = .running;
    live.status = .working;
    const handler: HistoryHandler = .{ .model = model };
    _ = handler.navigate(pane_id, .older);
    const query = (try handler.begin(pane_id)).?;
    try std.testing.expectEqualStrings("", query.anchor);
    var buffer: [4096]u8 = undefined;
    try std.testing.expect(try handler.apply(historyOperation(model, query.view_generation), try historyResponse(&buffer, query.view_generation)));
    const window = model.agentPane(pane_id).?.agent_history.?;
    try std.testing.expectEqual(@as(u8, 2), window.count);
    try std.testing.expect(!window.pages[1].snapshot.items()[0].complete);
    try std.testing.expectEqual(core.agent_thread.Status.working, live.status);
}

test "reversing within a page retires old work without loading the other edge" {
    const model = try historyModel();
    defer std.testing.allocator.destroy(model);
    defer model.deinit();
    const handler: HistoryHandler = .{ .model = model };
    _ = handler.navigate(pane_id, .older);
    const query = (try handler.begin(pane_id)).?;
    const operation = historyOperation(model, query.view_generation);
    handler.reverse(pane_id, .newer);
    const pane = model.agentPane(pane_id).?;
    try std.testing.expect(pane.agent_history.?.pending == null);
    try std.testing.expect(pane.history_intent == null);
    var buffer: [4096]u8 = undefined;
    try std.testing.expect(!try handler.apply(operation, try historyResponse(&buffer, query.view_generation)));
    try std.testing.expect(!handler.failed(operation, "Old request timed out"));
    try std.testing.expect(handler.navigate(pane_id, .older));
}

test "history ownership retains at most sixteen windows and evicts an inactive reader" {
    const model = try historyModel();
    defer std.testing.allocator.destroy(model);
    defer model.deinit();
    const handler: HistoryHandler = .{ .model = model };
    _ = handler.navigate(pane_id, .older);
    _ = try handler.begin(pane_id);
    try std.testing.expect(try handler.freeze(pane_id, model.agentPane(pane_id).?.attachment_generation));
    const selected = model.agentPane(pane_id).?.agent_history.?;
    for (2..18) |number| {
        const id: core.PaneId = @enumFromInt(number);
        _ = try model.createTab(.{ .created = .{ .location = .{ .workspace = location.workspace, .tab_id = @enumFromInt(number) }, .position = @intCast(number - 1), .label = "Agent", .root_pane_id = id, .kind = .agent, .pane_generation = 9 }, .size = .{ .cols = 40, .rows = 10 } });
        var bytes: [4096]u8 = undefined;
        var response = try readySnapshot(&bytes, 1);
        response.pane_id = id;
        _ = try model.applyAgentThread(response);
        model.workspace.findPane(id).?.agent_thread.?.truncated = true;
        try std.testing.expect(handler.navigate(id, .older));
        try std.testing.expect((try handler.begin(id)) != null);
    }
    var count: usize = 0;
    for (&model.workspace.items) |*entry| {
        const tab = if (entry.*) |*value| value else continue;
        for (&tab.model.panes) |*slot| {
            if (slot.*) |*pane| {
                count += @intFromBool(pane.agent_history != null);
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 16), count);
    try std.testing.expect(model.agentPane(@enumFromInt(17)).?.agent_history != null);
    try std.testing.expectEqual(selected, model.agentPane(pane_id).?.agent_history.?);
    try std.testing.expect(selected.retained);
    try std.testing.expect(@sizeOf(@import("../../panes/AgentHistoryWindow.zig")) <= 256 * 1024);
}

test "a live provider item without turn identity falls back to persisted tail" {
    const model = try historyModel();
    defer std.testing.allocator.destroy(model);
    defer model.deinit();
    model.agentPane(pane_id).?.agent_thread.?.item_storage[0].source_turn_len = 0;
    const handler: HistoryHandler = .{ .model = model };
    try std.testing.expect(handler.navigate(pane_id, .older));
    const query = (try handler.begin(pane_id)).?;
    try std.testing.expectEqualStrings("", query.anchor);
    try std.testing.expectEqualStrings("", query.anchor_turn);
}

test "selection freezes live bytes without provider work and returns to current live output" {
    const model = try historyModel();
    defer std.testing.allocator.destroy(model);
    defer model.deinit();
    const pane = model.agentPane(pane_id).?;
    const attachment = pane.attachment_generation;
    const handler: HistoryHandler = .{ .model = model };
    try std.testing.expect(!try handler.freeze(pane_id, attachment + 1));
    try std.testing.expect(pane.agent_history == null);
    try std.testing.expect(try handler.freeze(pane_id, attachment));
    const window = pane.agent_history.?;
    const generation = window.generation;
    try std.testing.expect(try handler.freeze(pane_id, attachment));
    try std.testing.expectEqual(generation, window.generation);
    try std.testing.expect(window.retained and window.selection_only);
    try std.testing.expect(window.pending == null and pane.history_intent == null);
    try std.testing.expect(!handler.navigate(pane_id, .older));
    try std.testing.expect(!handler.navigate(pane_id, .newer));
    try std.testing.expect(try handler.begin(pane_id) == null);
    @memcpy(pane.agent_thread.?.text_storage[0..5], "Later");
    try std.testing.expectEqualStrings("Ready", window.pages[0].snapshot.items()[0].text(&window.pages[0].snapshot));
    handler.unfreeze(pane_id, attachment + 1);
    try std.testing.expect(pane.agent_history != null);
    handler.unfreeze(pane_id, attachment);
    try std.testing.expect(pane.agent_history == null);
    try std.testing.expectEqualStrings("Later", pane.agent_thread.?.items()[0].text(pane.agent_thread.?));
}

test "selection retains historical pages and retires late provider responses before eviction" {
    const model = try historyModel();
    defer std.testing.allocator.destroy(model);
    defer model.deinit();
    const pane = model.agentPane(pane_id).?;
    const handler: HistoryHandler = .{ .model = model };
    try std.testing.expect(handler.navigate(pane_id, .older));
    const query = (try handler.begin(pane_id)).?;
    const operation = historyOperation(model, query.view_generation);
    const window = pane.agent_history.?;
    try std.testing.expect(try handler.freeze(pane_id, pane.attachment_generation));
    try std.testing.expect(window.retained and !window.selection_only);
    var buffer: [4096]u8 = undefined;
    try std.testing.expect(!try handler.apply(operation, try historyResponse(&buffer, query.view_generation)));
    try std.testing.expect(!handler.failed(operation, "Obsolete failure"));
    try std.testing.expectEqual(@as(u8, 1), window.count);
    try std.testing.expect(!window.failed);
    handler.unfreeze(pane_id, pane.attachment_generation);
    try std.testing.expectEqual(window, pane.agent_history.?);
    try std.testing.expect(!window.retained);
    try std.testing.expect(handler.navigate(pane_id, .older));
    const next = (try handler.begin(pane_id)).?;
    try std.testing.expect(next.view_generation != query.view_generation);
}

test "resumed snapshot loads history once and preserves a later composer draft" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    try bootstrap(&model);
    const handler: AgentThreadHandler = .{ .model = &model };
    try std.testing.expect(handler.edit(pane_id, .{ .insert = "Continue the parser work" }));
    var snapshot: core.AgentThreadSnapshot = .{ .pane_id = pane_id, .pane_generation = 9, .revision = 1, .status = .ready, .resumed = true, .truncated = true };
    @memcpy(snapshot.thread_id[0..8], "previous");
    snapshot.thread_id_len = 8;
    var storage: [96 * 1024]u8 = undefined;
    const view = (try core.decodeServer(try core.encodeAgentThreadSnapshot(&storage, &snapshot))).agent_thread_snapshot;
    try std.testing.expect(try handler.apply(view));
    const pane = model.workspace.findPane(pane_id).?;
    try std.testing.expectEqualStrings("Continue the parser work", pane.composerSlice());
    try std.testing.expectEqual(.older, pane.history_intent.?);
    pane.history_intent = null;
    snapshot.revision += 1;
    try std.testing.expect(try handler.apply((try core.decodeServer(try core.encodeAgentThreadSnapshot(&storage, &snapshot))).agent_thread_snapshot));
    try std.testing.expect(pane.history_intent == null);
}

test "a new conversation retires old history requests while preserving the next draft" {
    const model = try historyModel();
    defer std.testing.allocator.destroy(model);
    defer model.deinit();
    const pane = model.agentPane(pane_id).?;
    const history: HistoryHandler = .{ .model = model };
    const handler: AgentThreadHandler = .{ .model = model };
    try std.testing.expect(history.navigate(pane_id, .older));
    const query = (try history.begin(pane_id)).?;
    const operation = historyOperation(model, query.view_generation);
    try std.testing.expect(handler.edit(pane_id, .{ .insert = "Next question" }));
    var snapshot = pane.agent_thread.?.*;
    snapshot.revision += 1;
    @memcpy(snapshot.thread_id[0..3], "new");
    snapshot.thread_id_len = 3;
    snapshot.truncated = false;
    snapshot.item_count = 0;
    var bytes: [4096]u8 = undefined;
    try std.testing.expect(try handler.apply((try core.decodeServer(try core.encodeAgentThreadSnapshot(&bytes, &snapshot))).agent_thread_snapshot));
    try std.testing.expect(pane.agent_history == null);
    try std.testing.expect(pane.history_intent == null);
    try std.testing.expectEqualStrings("Next question", pane.composerSlice());
    try std.testing.expect(!try history.apply(operation, try historyResponse(&bytes, query.view_generation)));
}

test "image drafts survive failed admission later edits and stale acknowledgement" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    try bootstrap(&model);
    const handler: AgentThreadHandler = .{ .model = &model };
    var bytes: [4096]u8 = undefined;
    _ = try handler.apply(try readySnapshot(&bytes, 1));
    try std.testing.expect(try handler.attachImage(pane_id, "/tmp/first.png"));
    const prompt = handler.prompt(pane_id).?;
    try std.testing.expectEqualStrings("", prompt.text);
    try std.testing.expectEqual(@as(u8, 1), prompt.images.count);
    for (0..3) |_| {
        try std.testing.expect(try handler.attachImage(pane_id, "/tmp/next.png"));
    }

    try std.testing.expectError(error.TooManyAgentImages, handler.attachImage(pane_id, "/tmp/overflow.png"));
    var operation: AgentOperation = .{ .pane_id = pane_id, .pane_generation = prompt.pane_generation, .attachment_generation = prompt.attachment_generation, .location = location, .composer_content_revision = prompt.composer_content_revision };
    try std.testing.expect(!handler.complete(operation));
    try std.testing.expectEqual(@as(u8, 4), model.agentPane(pane_id).?.composerImages().count);
    operation.composer_content_revision = model.agentPane(pane_id).?.composer_content_revision;
    try std.testing.expect(handler.complete(operation));
    try std.testing.expectEqual(@as(u8, 0), model.agentPane(pane_id).?.composerImages().count);
}
