//! Runtime protocol contracts exercised through the concrete model dispatch.

const std = @import("std");
const core = @import("telar-core");
const LaunchTestFault = @import("../LaunchTestFault.zig");
const RequestFixture = @import("RequestFixture.zig");
const agent_control = @import("../agent_control.zig");
const agent_identity = @import("../agent_identity.zig");
const agent_status = @import("../agent_status.zig");
const agent_hooks = @import("../agent_hooks.zig");

const missing_pane: core.PaneId = @enumFromInt(99);
const missing_location: core.TabLocation = .{ .workspace = .{ .workspace = @enumFromInt(99) }, .tab_id = @enumFromInt(99) };

fn expectFailure(fixture: *RequestFixture, code: core.FailureCode) !void {
    const response = fixture.response() orelse return error.MissingFailure;
    try std.testing.expect(response.* == .request_failed);
    try std.testing.expectEqual(code, response.request_failed.code);
    try std.testing.expectEqual(@as(core.RequestId, @enumFromInt(41)), response.request_failed.request_id);
    fixture.clearResponses();
}

test "runtime dispatch counts stale one-way pane requests exactly once" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const messages = [_]core.ClientMessage{
        .{ .pane_input = .{ .pane_id = missing_pane, .bytes = "private" } },
        .{ .pane_resize = .{ .pane_id = missing_pane, .size = .{ .cols = 40, .rows = 10 } } },
        .{ .request_snapshot = .{ .pane_id = missing_pane, .known_frame_id = 0 } },
        .{ .detach_pane = .{ .pane_id = missing_pane } },
        .{ .request_graphics_snapshot = .{ .pane_id = missing_pane } },
        .{ .graphics_credit = .{ .pane_id = missing_pane, .bytes = 1 } },
        .{ .set_pane_viewport = .{ .pane_id = missing_pane, .offset = 10 } },
    };
    for (messages, 1..) |message, count| {
        try fixture.send(message);
        try std.testing.expectEqual(@as(u64, count), fixture.runtime.model.metrics.stale_client_messages);
        try std.testing.expect(fixture.response() == null);
    }
    try std.testing.expectEqual(@as(u64, 0), fixture.session.last_input_sequence);
}

test "runtime dispatch maps unavailable panes and tab snapshots to correlated failures" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const messages = [_]core.ClientMessage{
        .{ .open_pane = .{ .request_id = @enumFromInt(41), .target = .{ .pane = missing_pane }, .size = .{ .cols = 20, .rows = 5 }, .launch = null } },
        .{ .close_pane = .{ .request_id = @enumFromInt(41), .pane_id = missing_pane } },
        .{ .request_tab_snapshot = .{ .request_id = @enumFromInt(41), .location = missing_location } },
        .{ .close_tab = .{ .request_id = @enumFromInt(41), .location = missing_location } },
    };
    for (messages) |message| {
        try fixture.send(message);
        try expectFailure(&fixture, if (message == .request_tab_snapshot or message == .close_tab) .tab_not_found else .pane_not_found);
    }
}

test "runtime dispatch rejects an unavailable workspace without creating one" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const initial_revision = fixture.runtime.model.workspaces.revision;
    try fixture.send(.{ .request_workspace_snapshot = .{ .request_id = @enumFromInt(41), .workspace = missing_location.workspace } });
    try expectFailure(&fixture, .workspace_not_found);
    try std.testing.expectEqual(initial_revision, fixture.runtime.model.workspaces.revision);
}

test "runtime dispatch preserves a committed pane when its reply queue is full" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const first = try fixture.openPane();
    const count = fixture.runtime.model.panes.count;
    try fixture.fillResponses();
    var launch_buffer: [64]u8 = undefined;

    try std.testing.expectError(error.ResponseQueueFull, fixture.send(.{ .create_pane = .{
        .request_id = @enumFromInt(41),
        .location = first.location,
        .size = .{ .cols = 30, .rows = 8 },
        .launch = try RequestFixture.sleepLaunch(&launch_buffer),
    } }));
    try std.testing.expectEqual(count + 1, fixture.runtime.model.panes.count);
    try std.testing.expectEqual(@as(usize, 2), fixture.runtime.model.attachments.len(fixture.session.slot));
}

test "runtime dispatch retains tab rename after response backpressure" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const pane = try fixture.openPane();
    try fixture.fillResponses();

    try std.testing.expectError(error.ResponseQueueFull, fixture.send(.{ .rename_tab = .{
        .request_id = @enumFromInt(41),
        .location = pane.location,
        .label = "logs",
    } }));
    try std.testing.expectEqualStrings("logs", fixture.runtime.model.workspaces.tabLabel(pane.location).?);
}

test "runtime dispatch validates graphics credits against exact outstanding bytes" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const pane = try fixture.openPane();
    const attachment = fixture.runtime.model.attachments.find(fixture.session.slot, pane.id).?;
    const capacity = core.max_image_bytes_per_pane;
    attachment.graphics.credit = capacity - 16;
    try fixture.send(.{ .graphics_credit = .{ .pane_id = pane.id, .bytes = 16 } });
    try std.testing.expectEqual(capacity, attachment.graphics.credit);
    for ([_]u64{ 0, 1, std.math.maxInt(u64) }, 1..) |bytes, count| {
        try fixture.send(.{ .graphics_credit = .{ .pane_id = pane.id, .bytes = bytes } });
        try std.testing.expectEqual(capacity, attachment.graphics.credit);
        try std.testing.expectEqual(@as(u64, count), fixture.runtime.model.metrics.stale_client_messages);
    }
}

test "runtime dispatch keeps graphics configuration scoped to one connection" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const pane = try fixture.openPane();
    const other = try fixture.addClient();
    try fixture.send(.{ .configure_graphics = .{ .shared = true } });
    try std.testing.expect(fixture.session.shared_graphics);
    try std.testing.expect(!other.shared_graphics);
    try std.testing.expect(fixture.runtime.model.attachments.find(fixture.session.slot, pane.id) != null);
    try fixture.send(.{ .configure_graphics = .{ .shared = false } });
    try std.testing.expect(!fixture.session.shared_graphics);
    try std.testing.expectEqual(@as(u64, 0), fixture.runtime.model.metrics.stale_client_messages);
}

test "runtime stop records its first initiator and remains idempotent" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.send(.runtime_stop);
    try fixture.send(.runtime_stop);
    try std.testing.expect(fixture.runtime.model.shutdown.isRequested());
    try std.testing.expectEqualDeep(fixture.session.key, fixture.runtime.model.shutdown.initiator.?);
    try std.testing.expect(fixture.session.delivery.stopping());
}

test "runtime dispatch admits multiple viewers but preserves one geometry owner" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const pane = try fixture.openPane();
    const other = try fixture.addClient();
    const initial_size = pane.size;
    const requested_size: core.TerminalSize = .{ .cols = 44, .rows = 12 };
    try fixture.sendTo(other, .{ .open_pane = .{
        .request_id = @enumFromInt(41),
        .target = .{ .pane = pane.id },
        .size = requested_size,
        .launch = null,
    } });
    try std.testing.expect(fixture.runtime.model.attachments.find(other.slot, pane.id) != null);
    try std.testing.expectEqualDeep(initial_size, pane.size);
    try fixture.sendTo(other, .{ .pane_resize = .{ .pane_id = pane.id, .size = requested_size } });
    try std.testing.expectEqual(@as(u64, 1), fixture.runtime.model.metrics.geometry_rejections);
    try std.testing.expectEqualDeep(initial_size, pane.size);

    try fixture.send(.{ .detach_pane = .{ .pane_id = pane.id } });
    try fixture.sendTo(other, .{ .pane_resize = .{ .pane_id = pane.id, .size = requested_size } });
    try std.testing.expectEqualDeep(requested_size, pane.size);
    try std.testing.expectEqual(@as(u64, 1), fixture.runtime.model.metrics.geometry_rejections);
}

test "runtime dispatch defers geometry changes while output owns the terminal" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const pane = try fixture.openPane();
    const initial_size = pane.size;
    const requested_size: core.TerminalSize = .{ .cols = 44, .rows = 12 };
    pane.ingest_pending = true;
    defer pane.ingest_pending = false;
    try fixture.send(.{ .pane_resize = .{ .pane_id = pane.id, .size = requested_size } });
    try std.testing.expectEqualDeep(initial_size, pane.size);
    try std.testing.expectEqualDeep(requested_size, pane.pending_size.?);
    try std.testing.expectEqual(@as(u64, 0), fixture.runtime.model.metrics.geometry_rejections);
}

test "runtime dispatch rolls back a tab when post-spawn registration fails" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const pane = try fixture.openPane();
    const reader = &fixture.runtime.model.workspaces;
    const initial_tabs = reader.totalTabs();
    const initial_revision = reader.revision;
    var fault: LaunchTestFault = .{ .phase = .pane_registration };
    fixture.runtime.model.launch_fault = &fault;
    defer fixture.runtime.model.launch_fault = null;
    var launch_buffer: [64]u8 = undefined;
    try fixture.send(.{ .create_tab = .{
        .request_id = @enumFromInt(41),
        .workspace = pane.location.workspace,
        .label = "failed launch",
        .size = .{ .cols = 20, .rows = 5 },
        .launch = try RequestFixture.sleepLaunch(&launch_buffer),
    } });
    try expectFailure(&fixture, .spawn_failed);
    try std.testing.expect(fault.claimed.load(.acquire));
    try std.testing.expectEqual(initial_tabs, reader.totalTabs());
    try std.testing.expectEqual(initial_revision, reader.revision);
    try std.testing.expectEqual(@as(usize, 1), fixture.runtime.model.panes.count);
    try std.testing.expectEqual(@as(usize, 1), fixture.runtime.model.attachments.len(fixture.session.slot));
}

test "runtime dispatch reserves notification confirmation before publishing" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const other = try fixture.addClient();
    try fixture.fillResponses();
    try std.testing.expectError(error.ResponseQueueFull, fixture.send(.{ .show_notification = .{
        .request_id = @enumFromInt(41),
        .notification = .{ .title = "must not leak" },
    } }));
    try std.testing.expect(other.delivery.responses.peek() == null);
}

test "runtime dispatch rejects exited pane input without assigning recent-input authority" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const pane = try fixture.openPane();
    pane.exit = .{ .exited = 0 };
    defer pane.exit = null;
    try fixture.send(.{ .pane_input = .{ .pane_id = pane.id, .bytes = "ignored" } });
    try std.testing.expectEqual(@as(u64, 1), fixture.runtime.model.metrics.stale_client_messages);
    try std.testing.expectEqual(@as(u64, 0), fixture.session.last_input_sequence);
    try std.testing.expectEqual(core.PaneId.invalid, fixture.session.last_input_pane);
}

test "runtime dispatch owns routed command text and keeps its exact pending correlation" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    fixture.session.role = .control;
    const target = try fixture.addClient();
    target.delivery.client_identity = @enumFromInt(99);
    var command: core.ClientCommand = .{
        .request_id = @enumFromInt(41),
        .route = .{ .id = target.key.id, .generation = target.key.generation + 1 },
        .action = .client_clipboard_copy,
    };
    try command.setText("original draft");
    try fixture.send(.{ .request_client_command = command });
    try expectFailure(&fixture, .invalid_request);
    try std.testing.expect(target.delivery.responses.peek() == null);
    try std.testing.expect(fixture.session.pending_client_command == null);

    command.route.generation = target.key.generation;
    try fixture.send(.{ .request_client_command = command });
    try command.setText("changed draft");
    var reply = target.delivery.responses.peek().?.client_command;
    try std.testing.expectEqualStrings("original draft", reply.text());
    try std.testing.expectEqual(fixture.session.key.id, reply.route.id);
    try std.testing.expectEqual(fixture.session.key.generation, reply.route.generation);
    target.delivery.responses.clear();

    reply.status = .applied;
    reply.request_id = @enumFromInt(42);
    try fixture.sendTo(target, .{ .complete_client_command = reply });
    try std.testing.expect(fixture.session.pending_client_command != null);
    try std.testing.expect(fixture.response() == null);
    reply.request_id = @enumFromInt(41);
    try fixture.sendTo(target, .{ .complete_client_command = reply });
    try std.testing.expect(fixture.session.pending_client_command == null);
    try std.testing.expectEqual(target.key.id, fixture.response().?.client_command_result.route.id);
    try std.testing.expectEqualStrings("original draft", fixture.response().?.client_command_result.text());
}

test "a tab launched in the background keeps every focus where it was and takes text" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const model = &fixture.runtime.model;
    const focused = try fixture.openPane();
    const identity: core.ClientIdentity = @enumFromInt(5);
    fixture.session.delivery.client_identity = identity;
    const record = &model.client_layouts.records[0];
    record.identity = identity;
    record.active_tab = focused.location;
    record.tabs[0] = .{
        .location = focused.location,
        .focused_pane = focused.id,
        .fullscreen = false,
        .workspace_active = true,
        .node_count = 0,
    };
    record.tab_count = 1;
    const tabs_before = model.workspaces.totalTabs();

    var launch_buffer: [64]u8 = undefined;
    try fixture.send(.{ .launch_tab = .{
        .request_id = @enumFromInt(41),
        .workspace = focused.location.workspace.workspace,
        .label = "dispatch",
        .size = .{ .cols = 20, .rows = 5 },
        .launch = try RequestFixture.sleepLaunch(&launch_buffer),
    } });
    const response = fixture.response() orelse return error.MissingReply;
    try std.testing.expect(response.* == .pane_opened);
    const opened = response.pane_opened;
    fixture.clearResponses();

    try std.testing.expectEqual(tabs_before + 1, model.workspaces.totalTabs());
    try std.testing.expect(model.attachments.find(fixture.session.slot, opened.pane_id) == null);
    try std.testing.expect(agent_control.focusedByClient(model, focused.id));
    try std.testing.expect(!agent_control.focusedByClient(model, opened.pane_id));

    const background = model.panes.find(opened.pane_id).?;
    background.input_write_pending = true;
    defer {
        background.input_write_pending = false;
        background.input_queue.clear();
    }
    try fixture.send(.{ .send_pane_text = .{
        .request_id = @enumFromInt(41),
        .pane_id = opened.pane_id,
        .pane_generation = opened.pane_generation,
        .mode = .raw,
        .text = "echo hi",
    } });
    const typed = fixture.response() orelse return error.MissingReply;
    try std.testing.expect(typed.* == .request_completed);
    fixture.clearResponses();
    try std.testing.expectEqualStrings("echo hi", background.input_queue.nextChunk().?);

    try fixture.send(.{ .launch_tab = .{
        .request_id = @enumFromInt(41),
        .workspace = @enumFromInt(99),
        .label = "",
        .size = .{ .cols = 20, .rows = 5 },
        .launch = try RequestFixture.sleepLaunch(&launch_buffer),
    } });
    try expectFailure(&fixture, .workspace_not_found);
}

test "a hook reports for a pane only on a connection confirmed inside it and only for the agent the pane runs" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const pane = try fixture.openPane();
    const model = &fixture.runtime.model;
    const root = agent_identity.fromPane(pane).process_id;
    try std.testing.expect(agent_status.observeProcess(model, .{
        .identity = agent_identity.fromPane(pane),
        .provider = .claude,
        .process_id = root,
        .observed_at_ms = 1,
    }));

    const claude_report: core.ClientMessage = .{ .report_agent = .{
        .request_id = @enumFromInt(41),
        .pane_id = pane.id,
        .pane_generation = pane.generation,
        .provider = .claude,
        .state = .working,
        .session = "019a0000-0000-7000-8000-00000000000a",
    } };
    try fixture.send(claude_report);
    try expectFailure(&fixture, .foreign_process);

    try agent_hooks.finishDescent(model, .{
        .client = fixture.session.key,
        .request_id = @enumFromInt(41),
        .pane = pane.key(),
        .descends = false,
    });
    try expectFailure(&fixture, .foreign_process);
    try fixture.send(claude_report);
    try expectFailure(&fixture, .foreign_process);

    try agent_hooks.finishDescent(model, .{
        .client = fixture.session.key,
        .request_id = @enumFromInt(41),
        .pane = pane.key(),
        .descends = true,
    });
    try std.testing.expect(fixture.response().?.* == .request_completed);
    fixture.clearResponses();

    try fixture.send(.{ .report_agent = .{
        .request_id = @enumFromInt(41),
        .pane_id = pane.id,
        .pane_generation = pane.generation,
        .provider = .codex,
        .state = .working,
        .session = "019a0000-0000-7000-8000-00000000000b",
        .event = "\u{bb} Bash echo leak",
    } });
    try expectFailure(&fixture, .foreign_process);
    try fixture.send(.{ .report_agent_title = .{
        .request_id = @enumFromInt(41),
        .pane_id = pane.id,
        .pane_generation = pane.generation,
        .provider = .codex,
        .title = "leak",
    } });
    try expectFailure(&fixture, .foreign_process);
    try fixture.send(.{ .report_agent_command = .{
        .request_id = @enumFromInt(41),
        .pane_id = pane.id,
        .pane_generation = pane.generation,
        .phase = .started,
        .provider = "codex",
        .command = "echo leak",
    } });
    try expectFailure(&fixture, .foreign_process);
    try fixture.send(.{ .report_agent_progress = .{
        .request_id = @enumFromInt(41),
        .pane_id = pane.id,
        .pane_generation = pane.generation,
        .provider = .codex,
        .cwd = "/tmp",
        .final_message = "leak",
    } });
    try expectFailure(&fixture, .foreign_process);
    try std.testing.expect(agent_status.sessionReference(model, pane.key()) == null);

    try fixture.send(claude_report);
    try std.testing.expect(fixture.response().?.* == .request_completed);
    fixture.clearResponses();
    try std.testing.expectEqualStrings("019a0000-0000-7000-8000-00000000000a", agent_status.sessionReference(model, pane.key()).?.slice());

    // The confirmation names one generation; a report for another is refused.
    var stale = claude_report;
    stale.report_agent.pane_generation = pane.generation + 1;
    try fixture.send(stale);
    try expectFailure(&fixture, .pane_not_found);

    // A report that names no agent is the user's own and needs no descent.
    const observer = try fixture.addClient();
    try fixture.sendTo(observer, .{ .report_agent_title = .{
        .request_id = @enumFromInt(41),
        .pane_id = pane.id,
        .pane_generation = pane.generation,
        .title = "by hand",
    } });
    try std.testing.expect(observer.delivery.responses.peek().?.* == .request_completed);
}

test "a connection runs one descent check at a time" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const pane = try fixture.openPane();

    fixture.session.descent_pending = true;
    defer fixture.session.descent_pending = false;
    try fixture.send(.{ .verify_pane_descent = .{
        .request_id = @enumFromInt(41),
        .pane_id = pane.id,
        .pane_generation = pane.generation,
    } });
    try expectFailure(&fixture, .resource_limit);
}
