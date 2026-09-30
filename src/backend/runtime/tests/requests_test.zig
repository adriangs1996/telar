//! Runtime protocol contracts exercised through the concrete model dispatch.

const std = @import("std");
const core = @import("telar-core");
const LaunchTestFault = @import("../LaunchTestFault.zig");
const RequestFixture = @import("RequestFixture.zig");
const agent_control = @import("../agent_control.zig");
const agent_identity = @import("../agent_identity.zig");
const agent_status = @import("../agent_status.zig");
const agent_hooks = @import("../agent_hooks.zig");
const DescentCompletion = @import("../events/DescentCompletion.zig");
const Session = @import("../client/Session.zig");
const Pane = @import("../../pane/Pane.zig");
const client_connection = @import("../client_connection.zig");
const runtime_event = @import("../event.zig");
const SessionReference = @import("../../agent/SessionReference.zig");

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
        .node_start = 0,
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

    const claude_report: core.ClientMessage = .{
        .report_agent = .{
            .request_id = @enumFromInt(41),
            .pane_id = pane.id,
            .pane_generation = pane.generation,
            .provider = .claude,
            .state = .working,
            .session = "019a0000-0000-7000-8000-00000000000a",
        },
    };
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

    // The hook runs under a nested process (the tool Claude ran) under
    // Claude, the pane's root process.
    const nested: u32 = 999_001;
    var confirmed: DescentCompletion = .{
        .client = fixture.session.key,
        .request_id = @enumFromInt(41),
        .pane = pane.key(),
        .descends = true,
    };
    confirmed.ancestors[0] = nested;
    confirmed.ancestors[1] = root;
    confirmed.ancestor_count = 2;
    try agent_hooks.finishDescent(model, confirmed);
    try std.testing.expect(fixture.response().?.* == .request_completed);
    fixture.clearResponses();

    const codex_reports = [_]core.ClientMessage{
        .{
            .report_agent = .{
                .request_id = @enumFromInt(41),
                .pane_id = pane.id,
                .pane_generation = pane.generation,
                .provider = .codex,
                .state = .working,
                .session = "019a0000-0000-7000-8000-00000000000b",
                .event = "\u{bb} Bash echo leak",
            },
        },
        .{
            .report_agent_title = .{
                .request_id = @enumFromInt(41),
                .pane_id = pane.id,
                .pane_generation = pane.generation,
                .provider = .codex,
                .title = "leak",
            },
        },
        .{
            .report_agent_command = .{
                .request_id = @enumFromInt(41),
                .pane_id = pane.id,
                .pane_generation = pane.generation,
                .phase = .started,
                .provider = "codex",
                .command = "echo leak",
            },
        },
        .{
            .report_agent_progress = .{
                .request_id = @enumFromInt(41),
                .pane_id = pane.id,
                .pane_generation = pane.generation,
                .provider = .codex,
                .cwd = "/tmp",
                .final_message = "leak",
            },
        },
    };

    // An observation is already running, so the report waits for the
    // recheck after it: its reads pause and no answer is sent yet.
    try std.testing.expect(pane.history_observer.sealForProbe());
    pane.agent_recheck_running = true;
    try fixture.send(codex_reports[0]);
    try std.testing.expect(fixture.response() == null);
    try std.testing.expect(fixture.session.parked != null);
    try std.testing.expect(pane.agent_recheck_requested);
    try std.testing.expectEqual(pane.agent_rechecks +% 2, fixture.session.parked_recheck);

    // The running recheck completes: it may have read the process before
    // the report's agent replaced it, so the report keeps waiting.
    pane.agent_recheck_running = false;
    pane.agent_rechecks +%= 1;
    agent_hooks.answerParked(model, pane.key());
    try std.testing.expect(fixture.response() == null);

    // The next one still finds Claude: the report is refused, and the
    // nested process is remembered.
    pane.history_observer.finishSealed();
    pane.agent_recheck_requested = false;
    pane.agent_rechecks +%= 1;
    agent_hooks.answerParked(model, pane.key());
    try std.testing.expect(fixture.session.parked == null);
    try expectFailure(&fixture, .foreign_process);
    try std.testing.expectEqual(nested, pane.rejected_reporter.?.process);

    // Later reports of that process are refused at once, without
    // identifying the pane again.
    for (codex_reports) |message| {
        try fixture.send(message);
        try expectFailure(&fixture, .foreign_process);
        try std.testing.expect(fixture.session.parked == null);
        try std.testing.expect(!pane.agent_recheck_requested);
    }
    try std.testing.expect(agent_status.sessionReference(model, pane.key()) == null);

    // The pane's own agent still reports.
    try fixture.send(claude_report);
    try std.testing.expect(fixture.response().?.* == .request_completed);
    fixture.clearResponses();
    try std.testing.expectEqualStrings("019a0000-0000-7000-8000-00000000000a", agent_status.sessionReference(model, pane.key()).?.slice());

    // The confirmation names one generation; a report for another is refused.
    var stale = claude_report;
    stale.report_agent.pane_generation = pane.generation + 1;
    try fixture.send(stale);
    try expectFailure(&fixture, .pane_not_found);

    // The check found that Codex replaced Claude in the same process group.
    try std.testing.expect(agent_status.observeProcess(model, .{
        .identity = agent_identity.fromPane(pane),
        .provider = .codex,
        .process_id = root,
        .observed_at_ms = 2,
    }));
    try fixture.send(codex_reports[0]);
    try std.testing.expect(fixture.response().?.* == .request_completed);
    fixture.clearResponses();

    // A report that names no agent is the user's own and needs no descent.
    const observer = try fixture.addClient();
    try fixture.sendTo(observer, .{
        .report_agent_title = .{
            .request_id = @enumFromInt(41),
            .pane_id = pane.id,
            .pane_generation = pane.generation,
            .title = "by hand",
        },
    });
    try std.testing.expect(observer.delivery.responses.peek().?.* == .request_completed);
}

test "a connection runs one descent check at a time" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const pane = try fixture.openPane();

    fixture.session.descent_pending = true;
    defer fixture.session.descent_pending = false;
    try fixture.send(.{
        .verify_pane_descent = .{
            .request_id = @enumFromInt(41),
            .pane_id = pane.id,
            .pane_generation = pane.generation,
        },
    });
    try expectFailure(&fixture, .resource_limit);
}

test "a connection confirmed inside one pane cannot report for another" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const first = try fixture.openPane();
    var launch_buffer: [64]u8 = undefined;
    try fixture.send(.{
        .create_pane = .{
            .request_id = @enumFromInt(41),
            .location = first.location,
            .size = .{
                .cols = 30,
                .rows = 8,
            },
            .launch = try RequestFixture.sleepLaunch(&launch_buffer),
        },
    });
    fixture.clearResponses();
    const second_id = fixture.runtime.model.attachments.at(fixture.session.slot, 1).?.pane.id;
    const second = fixture.runtime.model.panes.find(second_id).?;

    try agent_hooks.finishDescent(&fixture.runtime.model, .{
        .client = fixture.session.key,
        .request_id = @enumFromInt(41),
        .pane = first.key(),
        .descends = true,
    });
    fixture.clearResponses();

    try fixture.send(.{
        .report_agent = .{
            .request_id = @enumFromInt(41),
            .pane_id = second.id,
            .pane_generation = second.generation,
            .provider = .codex,
            .state = .working,
        },
    });
    try expectFailure(&fixture, .foreign_process);
}

test "a descent check reads the peer from the socket, walks it in a worker and refuses a process outside the pane" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const pane = try fixture.openPane();

    // The peer of the fixture's socket pair is this test process, the
    // parent of the pane's root process, not one of its descendants.
    try fixture.send(.{
        .verify_pane_descent = .{
            .request_id = @enumFromInt(41),
            .pane_id = pane.id,
            .pane_generation = pane.generation,
        },
    });
    try std.testing.expect(fixture.session.descent_pending);
    try std.testing.expect(fixture.response() == null);

    var finished = false;
    for (0..64) |_| {
        const event = try fixture.runtime.loop.next();
        const descent = event == .pane_descent;
        _ = try fixture.runtime.update(event);
        if (descent) {
            finished = true;
            break;
        }
    }

    try std.testing.expect(finished);
    try std.testing.expect(!fixture.session.descent_pending);
    try std.testing.expect(fixture.session.hook_pane == null);
    try expectFailure(&fixture, .foreign_process);
}

test "attributing a worktree or sending review evidence for a pane takes a connection confirmed inside it" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const pane = try fixture.openPane();
    const model = &fixture.runtime.model;
    const registration: core.ClientMessage = .{
        .register_worktree = .{
            .request_id = @enumFromInt(41),
            .source = pane.location.workspace.workspace,
            .created_by = pane.id,
            .path = "/tmp/telar-worktrees/fix",
            .branch = "fix",
        },
    };

    try fixture.send(registration);
    try expectFailure(&fixture, .foreign_process);

    const root = agent_identity.fromPane(pane).process_id;
    try std.testing.expect(agent_status.observeProcess(model, .{
        .identity = agent_identity.fromPane(pane),
        .provider = .codex,
        .process_id = root,
        .observed_at_ms = 1,
    }));
    const reference = try SessionReference.init("019a0000-0000-7000-8000-00000000000a", 1);
    try std.testing.expect(agent_status.observeSessionReference(model, agent_identity.fromPane(pane), reference));
    try fixture.send(.{
        .report_change_review_sample = .{
            .request_id = @enumFromInt(41),
            .pane_id = pane.id,
            .pane_generation = pane.generation,
            .provider = .codex,
            .session = reference.slice(),
            .tool_call_id = "call-1",
            .phase = .before,
            .path = "/tmp/telar-worktrees/fix/a.txt",
            .exists = true,
            .content = "a",
        },
    });
    try expectFailure(&fixture, .foreign_process);

    try agent_hooks.finishDescent(model, .{
        .client = fixture.session.key,
        .request_id = @enumFromInt(41),
        .pane = pane.key(),
        .descends = true,
    });
    fixture.clearResponses();
    try fixture.send(registration);
    try std.testing.expect(fixture.response().?.* == .worktree_registered);
}

test "a report of another agent waits for the pane's process to be identified again and is then answered" {
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
    try agent_hooks.finishDescent(model, .{
        .client = fixture.session.key,
        .request_id = @enumFromInt(41),
        .pane = pane.key(),
        .descends = true,
    });
    fixture.clearResponses();

    // Codex took the pane without an exit the probe saw.
    try fixture.send(.{
        .report_agent = .{
            .request_id = @enumFromInt(41),
            .pane_id = pane.id,
            .pane_generation = pane.generation,
            .provider = .codex,
            .state = .ready,
            .session = "019a0000-0000-7000-8000-00000000000b",
        },
    });
    try std.testing.expect(fixture.session.parked != null);
    try std.testing.expect(pane.agent_recheck_running);
    try std.testing.expect(fixture.response() == null);
    const rechecks = pane.agent_rechecks;

    // The observation the refusal started runs with no output to replay.
    // The pane's root process is not an agent, so the pane has none, and
    // the parked report is taken.
    var answered = false;
    for (0..64) |_| {
        const event = try fixture.runtime.loop.next();
        const observed = event == .pane_observed;
        _ = try fixture.runtime.update(event);
        if (observed) {
            answered = true;
            break;
        }
    }

    try std.testing.expect(answered);
    try std.testing.expect(!pane.agent_recheck_running);
    try std.testing.expectEqual(rechecks +% 1, pane.agent_rechecks);
    try std.testing.expect(fixture.session.parked == null);
    try std.testing.expect(fixture.response().?.* == .request_completed);
    try std.testing.expectEqualStrings("019a0000-0000-7000-8000-00000000000b", agent_status.sessionReference(model, pane.key()).?.slice());
}

// A pane running Claude and a connection confirmed inside it whose hook ran
// under `lineage`, nearest first.
fn confirmUnder(fixture: *RequestFixture, session: *Session, pane: *Pane, lineage: []const u32) !void {
    var confirmed: DescentCompletion = .{
        .client = session.key,
        .request_id = @enumFromInt(41),
        .pane = pane.key(),
        .descends = true,
    };
    @memcpy(confirmed.ancestors[0..lineage.len], lineage);
    confirmed.ancestor_count = @intCast(lineage.len);
    try agent_hooks.finishDescent(&fixture.runtime.model, confirmed);
    session.delivery.responses.clear();
}

fn observeClaude(fixture: *RequestFixture, pane: *Pane, agent_pid: u32) !void {
    const identity = agent_identity.fromPane(pane);
    try std.testing.expect(agent_status.observeProcess(&fixture.runtime.model, .{
        .identity = identity,
        .provider = .claude,
        .process_id = identity.process_id,
        .observed_at_ms = 1,
        .agent_pid = agent_pid,
    }));
}

fn codexReport(pane: *const Pane, state: core.AgentReportState) core.ClientMessage {
    return .{
        .report_agent = .{
            .request_id = @enumFromInt(41),
            .pane_id = pane.id,
            .pane_generation = pane.generation,
            .provider = .codex,
            .state = state,
            .session = "019a0000-0000-7000-8000-00000000000b",
        },
    };
}

// Holds the pane's observer as a running observation does, so a parked
// report's recheck does not start in these tests.
fn holdObservation(pane: *Pane) !void {
    try std.testing.expect(pane.history_observer.sealForProbe());
}

test "a parked report pauses its connection's reads and they resume once it is answered" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const pane = try fixture.openPane();
    const root = agent_identity.fromPane(pane).process_id;
    try observeClaude(&fixture, pane, root);
    try confirmUnder(&fixture, fixture.session, pane, &.{ 999_001, root });
    try holdObservation(pane);
    defer pane.history_observer.finishSealed();

    const session = fixture.session;
    const message = codexReport(pane, .working);
    const payload = try core.encodeReportAgent(session.receive_buffer, message.report_agent);
    session.read_pending = true;
    client_connection.receive(&fixture.runtime.model, .{
        .client = session.key,
        .result = @constCast(payload),
    });
    try std.testing.expect(session.parked != null);
    try std.testing.expect(!session.read_pending);
    try std.testing.expect(fixture.response() == null);

    pane.agent_rechecks +%= 1;
    agent_hooks.answerParked(&fixture.runtime.model, pane.key());
    try std.testing.expect(session.parked == null);
    try std.testing.expect(session.read_pending);
    try expectFailure(&fixture, .foreign_process);
}

test "parked reports are answered in the order they arrived, with the time they arrived" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const pane = try fixture.openPane();
    const model = &fixture.runtime.model;
    const root = agent_identity.fromPane(pane).process_id;
    try observeClaude(&fixture, pane, root);
    const first = try fixture.addClient();
    const second = fixture.session;
    try confirmUnder(&fixture, first, pane, &.{root});
    try confirmUnder(&fixture, second, pane, &.{root});
    try holdObservation(pane);
    defer pane.history_observer.finishSealed();

    // The working report arrives first, on the connection in the later
    // slot; the settled one after it.
    try fixture.sendTo(first, codexReport(pane, .working));
    const working_at = first.parked_real_ms;
    try fixture.sendTo(second, codexReport(pane, .ready));
    try std.testing.expect(first.parked != null and second.parked != null);

    // The check found that Codex replaced Claude.
    try std.testing.expect(agent_status.observeProcess(model, .{
        .identity = agent_identity.fromPane(pane),
        .provider = .codex,
        .process_id = root,
        .observed_at_ms = working_at + 1_000,
    }));
    pane.agent_rechecks +%= 1;
    agent_hooks.answerParked(model, pane.key());

    try std.testing.expect(first.delivery.responses.peek().?.* == .request_completed);
    try std.testing.expect(second.delivery.responses.peek().?.* == .request_completed);
    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    const entry = agent_status.snapshot(&model.agents, &entries, working_at + 2_000)[0];
    try std.testing.expect(entry.status == .ready or entry.status == .done);
    try std.testing.expect(entry.observed_at_ms < working_at + 1_000);
}

test "a parked report whose pane is gone or whose recheck is late is answered on the tick" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const pane = try fixture.openPane();
    const model = &fixture.runtime.model;
    const root = agent_identity.fromPane(pane).process_id;
    try observeClaude(&fixture, pane, root);
    try confirmUnder(&fixture, fixture.session, pane, &.{root});
    try holdObservation(pane);
    defer pane.history_observer.finishSealed();

    try fixture.send(codexReport(pane, .working));
    agent_hooks.expireParked(model);
    try std.testing.expect(fixture.session.parked != null);

    fixture.session.parked_at_ms -= 2_000;
    agent_hooks.expireParked(model);
    try std.testing.expect(fixture.session.parked == null);
    try expectFailure(&fixture, .foreign_process);

    try fixture.send(codexReport(pane, .working));
    try std.testing.expect(fixture.session.parked != null);
    pane.exit = .{ .exited = 0 };
    defer pane.exit = null;
    agent_hooks.expireParked(model);
    try std.testing.expect(fixture.session.parked == null);
    try expectFailure(&fixture, .pane_not_found);
}

test "a connection that closes while its report is parked is released at once" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const pane = try fixture.openPane();
    const model = &fixture.runtime.model;
    const root = agent_identity.fromPane(pane).process_id;
    try observeClaude(&fixture, pane, root);
    const hook = try fixture.addClient();
    hook.send_pending = false;
    try confirmUnder(&fixture, hook, pane, &.{root});
    try holdObservation(pane);
    defer pane.history_observer.finishSealed();

    try fixture.sendTo(hook, codexReport(pane, .working));
    const key = hook.key;
    try std.testing.expect(hook.parked != null);

    // A parked connection reads and writes nothing, so it goes at once,
    // and its report with it.
    client_connection.drop(model, key);
    try std.testing.expect(model.clients.resolve(key) == null);

    pane.agent_rechecks +%= 1;
    agent_hooks.answerParked(model, pane.key());
    agent_hooks.expireParked(model);
    try std.testing.expect(fixture.response() == null);
}

test "a report that cannot start its recheck is refused for lack of resources, and the connection stays" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const pane = try fixture.openPane();
    const model = &fixture.runtime.model;
    const root = agent_identity.fromPane(pane).process_id;
    try observeClaude(&fixture, pane, root);
    try confirmUnder(&fixture, fixture.session, pane, &.{root});

    var storage: [1]runtime_event.Event = undefined;
    var unavailable: std.Io.Select(runtime_event.Event) = .init(std.Io.failing, &storage);
    const select = model.select;
    model.select = &unavailable;
    defer model.select = select;

    try fixture.send(codexReport(pane, .working));
    try std.testing.expect(fixture.session.parked == null);
    try expectFailure(&fixture, .resource_limit);
    try std.testing.expect(model.clients.resolve(fixture.session.key) != null);
}

test "a refused reporter is remembered by the process under the pane's agent, or under its root, never by the agent itself" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const pane = try fixture.openPane();
    const model = &fixture.runtime.model;
    const root = agent_identity.fromPane(pane).process_id;
    // A wrapper leads the pane's group and runs Claude as its child.
    const claude: u32 = 999_010;
    try observeClaude(&fixture, pane, claude);
    try holdObservation(pane);
    defer pane.history_observer.finishSealed();

    const cases = [_]struct {
        lineage: []const u32,
        remembered: ?u32,
    }{
        // A tool Claude ran.
        .{
            .lineage = &.{ 999_020, 999_021, claude, root },
            .remembered = 999_021,
        },
        // An agent in the background of the pane's shell.
        .{
            .lineage = &.{ 999_030, 999_031, root },
            .remembered = 999_031,
        },
        // Claude itself, which may have replaced itself by exec.
        .{
            .lineage = &.{ claude, root },
            .remembered = null,
        },
    };

    for (cases) |case| {
        pane.rejected_reporter = null;
        try confirmUnder(&fixture, fixture.session, pane, case.lineage);
        try fixture.send(codexReport(pane, .working));
        try std.testing.expect(fixture.session.parked != null);
        pane.agent_rechecks +%= 1;
        agent_hooks.answerParked(model, pane.key());
        try expectFailure(&fixture, .foreign_process);

        if (case.remembered) |process| {
            try std.testing.expectEqual(process, pane.rejected_reporter.?.process);
            try std.testing.expectEqual(claude, pane.rejected_reporter.?.agent);
            try fixture.send(codexReport(pane, .working));
            try std.testing.expect(fixture.session.parked == null);
            try expectFailure(&fixture, .foreign_process);
        } else {
            try std.testing.expect(pane.rejected_reporter == null);
        }
    }
}

test "a report parked behind a running recheck is answered once its agent is accepted, before a later direct report" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const pane = try fixture.openPane();
    const model = &fixture.runtime.model;
    const root = agent_identity.fromPane(pane).process_id;
    try observeClaude(&fixture, pane, root);
    const first = try fixture.addClient();
    const second = try fixture.addClient();
    const third = fixture.session;
    for ([_]*Session{ first, second, third }) |session| {
        try confirmUnder(&fixture, session, pane, &.{root});
    }
    try holdObservation(pane);
    defer pane.history_observer.finishSealed();

    // A parks and starts a recheck; B arrives while it runs and waits for
    // the one after it.
    try fixture.sendTo(first, codexReport(pane, .working));
    pane.agent_recheck_running = true;
    try fixture.sendTo(second, codexReport(pane, .working));
    try std.testing.expectEqual(first.parked_recheck +% 1, second.parked_recheck);

    // The first recheck finds Codex: A is due, and B's agent is accepted.
    pane.agent_recheck_running = false;
    pane.agent_rechecks +%= 1;
    try std.testing.expect(agent_status.observeProcess(model, .{
        .identity = agent_identity.fromPane(pane),
        .provider = .codex,
        .process_id = root,
        .observed_at_ms = 5,
    }));
    agent_hooks.answerParked(model, pane.key());
    try std.testing.expect(first.parked == null and second.parked == null);
    try std.testing.expect(second.delivery.responses.peek().?.* == .request_completed);

    // C settles the turn directly and nothing older overrides it.
    try fixture.sendTo(third, codexReport(pane, .ready));
    try std.testing.expect(third.delivery.responses.peek().?.* == .request_completed);
    pane.agent_rechecks +%= 1;
    agent_hooks.answerParked(model, pane.key());
    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    const status = agent_status.snapshot(&model.agents, &entries, std.Io.Timestamp.now(model.io, .real).toMilliseconds())[0].status;
    try std.testing.expect(status == .ready or status == .done);
}

test "a report answered because its recheck was late is refused without being remembered" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const pane = try fixture.openPane();
    const root = agent_identity.fromPane(pane).process_id;
    try observeClaude(&fixture, pane, root);
    try confirmUnder(&fixture, fixture.session, pane, &.{ 999_031, root });
    try holdObservation(pane);
    defer pane.history_observer.finishSealed();

    try fixture.send(codexReport(pane, .working));
    fixture.session.parked_at_ms -= 2_000;
    agent_hooks.expireParked(&fixture.runtime.model);
    try expectFailure(&fixture, .foreign_process);
    try std.testing.expect(pane.rejected_reporter == null);
}

test "a probe that identifies another process forgets the rejected reporter" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const pane = try fixture.openPane();
    const root = agent_identity.fromPane(pane).process_id;
    try observeClaude(&fixture, pane, root);
    pane.rejected_reporter = .{
        .group = root,
        .agent = root,
        .process = 999_031,
    };

    pane.agent_recheck_requested = true;
    const borrow = pane.beginHistoryObservation().?;
    var cache = borrow.process_cache;
    cache.process_group_id = root;
    cache.provider = .codex;
    try std.testing.expect(!try fixture.runtime.update(.{
        .pane_observed = .{
            .pane = pane.key(),
            .stats = .{},
            .process_probe = .{
                .cache = cache,
                .changed = true,
                .inspected = true,
            },
        },
    }));
    try std.testing.expect(pane.rejected_reporter == null);
}
