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

test "proxy status reconciliation commits only changed runtime state" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();

    try std.testing.expect(model.reconcileProxyStatus(.{ .active = false, .scope = .exact, .system_trusted = false }) == null);
    try std.testing.expect(!model.proxyTlsActive());
    try std.testing.expectEqualDeep(client_model.Version{}, model.version());

    const enabled = model.reconcileProxyStatus(.{ .active = true, .scope = .wildcard, .system_trusted = false }).?;

    try std.testing.expect(!enabled.previous);
    try std.testing.expect(enabled.active);
    try std.testing.expectEqual(schema.ProxyScope.wildcard, enabled.scope);
    try std.testing.expectEqual(@as(u64, 0), enabled.proxy_status_revision_before);
    try std.testing.expectEqual(@as(u64, 1), enabled.proxy_status_revision);
    try std.testing.expect(model.proxyTlsActive());
    try std.testing.expectEqual(client_model.Version{ .proxy_status = 1 }, model.version());
    try std.testing.expect(model.reconcileProxyStatus(.{ .active = true, .scope = .wildcard, .system_trusted = false }) == null);
    try std.testing.expectEqual(client_model.Version{ .proxy_status = 1 }, model.version());

    const disabled = model.reconcileProxyStatus(.{ .active = false, .scope = .exact, .system_trusted = false }).?;

    try std.testing.expect(disabled.previous);
    try std.testing.expect(!disabled.active);
    try std.testing.expectEqual(@as(u64, 1), disabled.proxy_status_revision_before);
    try std.testing.expectEqual(@as(u64, 2), disabled.proxy_status_revision);
    try std.testing.expect(!model.proxyTlsActive());
    try std.testing.expectEqual(client_model.Version{ .proxy_status = 2 }, model.version());

    const trusted = model.reconcileProxyStatus(.{ .active = false, .scope = .exact, .system_trusted = true }).?;

    try std.testing.expect(!trusted.previous_system_trusted);
    try std.testing.expect(trusted.system_trusted);
    try std.testing.expect(model.proxySystemTrusted());
    try std.testing.expectEqual(client_model.Version{ .proxy_status = 3 }, model.version());
}

test "system metrics reconciliation owns the latest replica and one isolated revision" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();

    const first = (try model.reconcileSystemMetrics(.{
        .runtime_revision = 4,
        .cpu_percent = 25,
        .memory_used_decigib = 123,
        .battery_percent = null,
    })).?;

    try std.testing.expectEqual(@as(u64, 4), first.runtime_revision);
    try std.testing.expectEqual(@as(u64, 1), first.system_metrics_revision);
    try std.testing.expectEqual(client_model.Version{ .system_metrics = 1 }, model.version());
    try std.testing.expectEqualDeep(client_model.SystemMetrics{
        .runtime_revision = 4,
        .cpu_percent = 25,
        .memory_used_decigib = 123,
        .battery_percent = null,
    }, model.systemMetrics().?);

    try std.testing.expect((try model.reconcileSystemMetrics(.{
        .runtime_revision = 3,
        .cpu_percent = 10,
        .memory_used_decigib = 20,
        .battery_percent = 90,
    })) == null);
    try std.testing.expectEqual(client_model.Version{ .system_metrics = 1 }, model.version());

    const second = (try model.reconcileSystemMetrics(.{
        .runtime_revision = 5,
        .cpu_percent = 50,
        .memory_used_decigib = 10,
        .battery_percent = 80,
    })).?;

    try std.testing.expectEqual(@as(u64, 2), second.system_metrics_revision);
    try std.testing.expectEqual(@as(?u8, 80), model.systemMetrics().?.battery_percent);
    try std.testing.expectEqual(client_model.Version{ .system_metrics = 2 }, model.version());
}

test "rejected system metrics preserve the latest replica and version" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const initial: client_model.SystemMetrics = .{
        .runtime_revision = 1,
        .cpu_percent = 30,
        .memory_used_decigib = 80,
        .battery_percent = null,
    };
    _ = try model.reconcileSystemMetrics(initial);

    try std.testing.expectError(error.InvalidMetricsRevision, model.reconcileSystemMetrics(.{
        .runtime_revision = 0,
        .cpu_percent = 30,
        .memory_used_decigib = 80,
        .battery_percent = null,
    }));
    try std.testing.expectError(error.InvalidMetricsValue, model.reconcileSystemMetrics(.{
        .runtime_revision = 2,
        .cpu_percent = 101,
        .memory_used_decigib = 80,
        .battery_percent = null,
    }));
    try std.testing.expectError(error.InvalidMetricsValue, model.reconcileSystemMetrics(.{
        .runtime_revision = 3,
        .cpu_percent = 30,
        .memory_used_decigib = 80,
        .battery_percent = 101,
    }));

    try std.testing.expectEqualDeep(initial, model.systemMetrics().?);
    try std.testing.expectEqual(client_model.Version{ .system_metrics = 1 }, model.version());
}

test "notification lifecycle is model-owned and versioned by semantic change" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var title = [_]u8{ 'R', 'e', 'a', 'd', 'y' };
    const tab_id: schema.TabId = @enumFromInt(7);
    const started_ns: u64 = 100;

    const publication = model.publishNotification(started_ns, .{
        .level = .success,
        .title = &title,
        .message = "Open completed tab",
        .target = .{ .select_tab = tab_id },
    });
    @memset(&title, 'x');

    try std.testing.expectEqual(client_model.Version{ .notifications = 1 }, model.version());
    try std.testing.expectEqualStrings("Ready", model.notificationSnapshot().itemAt(0).?.title());
    try std.testing.expectEqual(
        started_ns + std.time.ns_per_s / 60,
        model.nextNotificationDeadline(started_ns, std.time.ns_per_s / 60).?,
    );

    const activation_ns = started_ns + notifications.transition_duration_ns;
    const activation = model.activateNotification(publication.id, activation_ns).?;

    try std.testing.expectEqual(tab_id, activation.target.select_tab);
    try std.testing.expectEqual(@as(u64, 2), activation.notifications_revision);
    try std.testing.expectEqual(client_model.Version{ .notifications = 2 }, model.version());
    try std.testing.expect(model.activateNotification(publication.id, activation_ns) == null);
    try std.testing.expectEqual(client_model.Version{ .notifications = 2 }, model.version());

    const removal = model.advanceNotifications(activation_ns + notifications.transition_duration_ns).?;

    try std.testing.expectEqual(@as(u64, 3), removal.notifications_revision);
    try std.testing.expect(!model.notificationSnapshot().hasItems());
    try std.testing.expectEqual(client_model.Version{ .notifications = 3 }, model.version());

    const second = model.publishNotification(1000, .{ .title = "Saved", .message = "Done" });
    const dismissed = model.dismissNotification(second.id, 1001).?;

    try std.testing.expectEqual(@as(u64, 5), dismissed.notifications_revision);
    try std.testing.expect(model.dismissNotification(second.id, 1001) == null);
    try std.testing.expectEqual(client_model.Version{ .notifications = 5 }, model.version());
}

test "agent reconciliation owns labels versions and existing status transitions" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const key: agents.AgentKey = .{ .pane_id = @enumFromInt(7), .pane_generation = 2 };
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    var title = [_]u8{ 'f', 'i', 'r', 's', 't' };
    var agent: agents.AgentInput = .{
        .key = key,
        .location = location,
        .pane_index = 3,
        .session_title = &title,
        .provider = .codex,
        .status = .working,
    };

    const first = (try model.reconcileAgentSnapshot(.{
        .revision = 4,
        .agents = &.{agent},
    })).?;
    title[0] = 'x';

    try std.testing.expectEqual(@as(u64, 4), first.runtime_revision);
    try std.testing.expectEqual(@as(usize, 1), first.count);
    try std.testing.expectEqual(@as(usize, 0), first.status_changes.slice().len);
    try std.testing.expectEqual(@as(u64, 0), first.agent_revision_before);
    try std.testing.expectEqual(@as(u64, 1), first.agent_revision);
    try std.testing.expectEqual(client_model.Version{ .agents = 1 }, model.version());
    try std.testing.expectEqualStrings("first", model.agentSnapshot().find(key).?.sessionTitle());
    try std.testing.expect(model.knowsAgent(key));
    try std.testing.expect(model.sidebarAnimationActive());

    agent.session_title = "second";
    agent.status = .ready;
    const second = (try model.reconcileAgentSnapshot(.{
        .revision = 5,
        .agents = &.{agent},
    })).?;
    const change = second.status_changes.slice()[0];

    try std.testing.expectEqual(@as(u64, 1), second.agent_revision_before);
    try std.testing.expectEqual(@as(u64, 2), second.agent_revision);
    try std.testing.expectEqual(@as(usize, 1), second.status_changes.slice().len);
    try std.testing.expectEqualDeep(key, change.key);
    try std.testing.expectEqual(schema.AgentStatus.working, change.previous);
    try std.testing.expectEqual(schema.AgentStatus.ready, change.current);
    try std.testing.expectEqual(@as(u16, 3), change.pane_index);
    try std.testing.expectEqual(schema.AgentProvider.codex, change.provider);
    try std.testing.expect(!model.sidebarAnimationActive());
    try std.testing.expect((try model.reconcileAgentSnapshot(.{
        .revision = 5,
        .agents = &.{agent},
    })) == null);
    try std.testing.expectEqual(client_model.Version{ .agents = 2 }, model.version());
}

test "sidebar animation advances its own revision only while active" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var agent: agents.AgentInput = .{
        .key = .{ .pane_id = @enumFromInt(7), .pane_generation = 2 },
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        },
        .pane_index = 1,
        .provider = .codex,
        .status = .ready,
    };
    _ = try model.reconcileAgentSnapshot(.{ .revision = 1, .agents = &.{agent} });

    try std.testing.expect(model.advanceSidebarAnimation() == null);
    try std.testing.expectEqual(@as(u8, 0), model.sidebarAnimationFrame());
    try std.testing.expectEqual(client_model.Version{ .agents = 1 }, model.version());

    agent.status = .working;
    _ = try model.reconcileAgentSnapshot(.{ .revision = 2, .agents = &.{agent} });
    const first = model.advanceSidebarAnimation().?;
    const second = model.advanceSidebarAnimation().?;

    try std.testing.expectEqual(@as(u8, 1), first.frame);
    try std.testing.expectEqual(@as(u64, 1), first.sidebar_animation_revision);
    try std.testing.expectEqual(@as(u8, 2), second.frame);
    try std.testing.expectEqual(@as(u64, 2), second.sidebar_animation_revision);
    try std.testing.expectEqual(@as(u8, 2), model.sidebarAnimationFrame());
    try std.testing.expectEqual(client_model.Version{
        .agents = 2,
        .sidebar_animation = 2,
    }, model.version());
}

test "rejected agent reconciliation preserves replica and version" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const agent: agents.AgentInput = .{
        .key = .{ .pane_id = @enumFromInt(7), .pane_generation = 2 },
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        },
        .pane_index = 1,
        .provider = .codex,
        .status = .working,
    };
    _ = try model.reconcileAgentSnapshot(.{ .revision = 1, .agents = &.{agent} });

    try std.testing.expectError(error.DuplicateAgent, model.reconcileAgentSnapshot(.{
        .revision = 2,
        .agents = &.{ agent, agent },
    }));
    const oversized: [agents.max_agents + 1]agents.AgentInput = @splat(agent);
    try std.testing.expectError(error.TooManyAgents, model.reconcileAgentSnapshot(.{
        .revision = 3,
        .agents = &oversized,
    }));

    try std.testing.expectEqual(client_model.Version{ .agents = 1 }, model.version());
    try std.testing.expectEqual(@as(u64, 1), model.agentSnapshot().revision);
    try std.testing.expect(model.knowsAgent(agent.key));
}

test "agent navigation and focused attachments derive from committed client state" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const first: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const second: schema.TabLocation = .{
        .workspace = first.workspace,
        .tab_id = @enumFromInt(2),
    };
    const local_key: agents.AgentKey = .{
        .pane_id = @enumFromInt(1),
        .pane_generation = 4,
    };
    const remote_key: agents.AgentKey = .{
        .pane_id = @enumFromInt(9),
        .pane_generation = 3,
    };
    try model.workspace.bootstrap(local_key.pane_id, first, .{ .cols = 20, .rows = 5 });
    const agent_entries = [_]agents.AgentInput{
        .{
            .key = local_key,
            .location = first,
            .pane_index = 1,
            .provider = .claude,
            .attachments = .stable_number,
            .status = .ready,
        },
        .{
            .key = remote_key,
            .location = .{
                .workspace = .{ .workspace = @enumFromInt(3) },
                .tab_id = @enumFromInt(6),
            },
            .pane_index = 2,
            .provider = .codex,
            .attachments = .ordered,
            .status = .working,
        },
    };
    _ = try model.reconcileAgentSnapshot(.{ .revision = 1, .agents = &agent_entries });

    try std.testing.expectEqualDeep(local_key, model.focusedAttachmentAgent().?);
    try std.testing.expectEqualDeep(attachments.Target{
        .pane_id = local_key.pane_id,
        .pane_generation = local_key.pane_generation,
    }, model.focusedAttachmentTarget().?);
    try std.testing.expectEqualDeep(client_model.LocalAgentNavigation{
        .pane_id = local_key.pane_id,
        .select_tab = null,
    }, model.planAgentNavigation(local_key).?.local);
    try std.testing.expectEqualDeep(client_model.AgentHandoff{
        .pane_id = remote_key.pane_id,
        .fallback_workspace = @enumFromInt(3),
    }, model.planAgentNavigation(remote_key).?.handoff);

    _ = try model.workspace.addCreated(.{
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });

    try std.testing.expect(model.focusedAttachmentAgent() == null);
    try std.testing.expect(model.focusedAttachmentTarget() == null);
    try std.testing.expectEqualDeep(client_model.LocalAgentNavigation{
        .pane_id = local_key.pane_id,
        .select_tab = first.tab_id,
    }, model.planAgentNavigation(local_key).?.local);
    try std.testing.expect(model.planAgentNavigation(.{
        .pane_id = remote_key.pane_id,
        .pane_generation = remote_key.pane_generation + 1,
    }) == null);
}

test "focused done agent is acknowledged once per completion without a version change" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const key: agents.AgentKey = .{
        .pane_id = @enumFromInt(1),
        .pane_generation = 4,
    };
    try model.workspace.bootstrap(key.pane_id, location, .{ .cols = 20, .rows = 5 });
    var entry: agents.AgentInput = .{
        .key = key,
        .location = location,
        .pane_index = 1,
        .provider = .claude,
        .status = .working,
    };
    _ = try model.reconcileAgentSnapshot(.{ .revision = 1, .agents = &.{entry} });

    try std.testing.expect(model.takeAgentAcknowledgement() == null);

    entry.status = .done;
    _ = try model.reconcileAgentSnapshot(.{ .revision = 2, .agents = &.{entry} });
    const version = model.version();

    try std.testing.expectEqualDeep(key, model.takeAgentAcknowledgement().?);
    try std.testing.expect(model.takeAgentAcknowledgement() == null);
    try std.testing.expectEqualDeep(version, model.version());

    entry.status = .ready;
    _ = try model.reconcileAgentSnapshot(.{ .revision = 3, .agents = &.{entry} });
    try std.testing.expect(model.takeAgentAcknowledgement() == null);

    entry.status = .done;
    _ = try model.reconcileAgentSnapshot(.{ .revision = 4, .agents = &.{entry} });
    try std.testing.expectEqualDeep(key, model.takeAgentAcknowledgement().?);
}

test "an unfocused done agent is never acknowledged" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const first: schema.PaneId = @enumFromInt(1);
    const second: schema.PaneId = @enumFromInt(2);
    const area: ui.Rect = .{ .w = 80, .h = 24 };
    try model.workspace.bootstrap(first, location, .{ .cols = 80, .rows = 24 });
    try model.workspace.active().?.model.split(.{ .existing_pane = first, .new_pane = second, .location = location, .axis = .horizontal, .area = area });
    const done_key: agents.AgentKey = .{ .pane_id = first, .pane_generation = 2 };
    const entry: agents.AgentInput = .{
        .key = done_key,
        .location = location,
        .pane_index = 1,
        .provider = .codex,
        .status = .done,
    };
    _ = try model.reconcileAgentSnapshot(.{ .revision = 1, .agents = &.{entry} });
    _ = model.focusPane(.{ .target = .{ .pane_id = second }, .area = area });

    try std.testing.expect(model.takeAgentAcknowledgement() == null);

    _ = model.focusPane(.{ .target = .{ .pane_id = first }, .area = area });

    try std.testing.expectEqualDeep(done_key, model.takeAgentAcknowledgement().?);
}

test "pane titles are stored per pane and exposed for the focused pane" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(pane, location, .{ .cols = 20, .rows = 5 });
    try std.testing.expectEqualStrings("", model.focusedPaneTitle());

    const commit = (try model.updatePaneMetadata(.{ .title = .{ .pane_id = pane, .title = "vim" } })).?;

    try std.testing.expectEqual(client_model.PaneMetadataKind.title, commit.kind);
    try std.testing.expect(commit.display_changed);
    try std.testing.expectEqualStrings("vim", model.focusedPaneTitle());
    try std.testing.expect(try model.updatePaneMetadata(.{ .title = .{ .pane_id = pane, .title = "vim" } }) == null);
    try std.testing.expect(try model.updatePaneMetadata(.{ .title = .{ .pane_id = @enumFromInt(9), .title = "x" } }) == null);

    _ = (try model.updatePaneMetadata(.{ .title = .{ .pane_id = pane, .title = "" } })).?;
    try std.testing.expectEqualStrings("", model.focusedPaneTitle());
}

test "a host background report resolves the appearance by luminance" {
    const light = client_model.HostCapabilities{};
    const bright = light.withObservation(.{ .background = .{ .r = 0xee, .g = 0xee, .b = 0xee } });
    try std.testing.expectEqual(client_model.HostAppearance.light, bright.appearance);

    const dim = light.withObservation(.{ .background = .{ .r = 0x1e, .g = 0x22, .b = 0x2e } });
    try std.testing.expectEqual(client_model.HostAppearance.dark, dim.appearance);
    try std.testing.expectEqual(client_model.HostAppearance.dark, dim.withExpiredProbes().appearance);
}
