//! Plugin actions: runs plugin actions on a worker, applies their results and
//! answers plugin commands.
const plugin_action = @import("../input/plugin_action.zig");
const data = @import("model");
const core = @import("telar-core");
const std = @import("std");
const client_diagnostic = @import("../config/client_diagnostic.zig");
const plugin_action_delivery = @import("../input/plugin_action_delivery.zig");
const Registry = @import("Registry.zig");
const ConfiguredPlugins = @import("ConfiguredPlugins.zig");
const actions = @import("../input/actions.zig");
const notifications = @import("../notifications/notifications.zig");
const Client = @import("../execution/Client.zig");

/// Consumes one worker completion and applies its authorized action batch,
/// which a successful worker left in `client.plugin_result`.
/// Example: `_ = try plugin_actions.completePluginAction(app, completion);`
pub fn completePluginAction(client: *Client, completion: data.PluginActionsCompletion) !bool {
    const stored = &client.plugin_result;
    const command: plugin_action.CompletionCommand = if (completion.result) |_|
        .{
            .succeeded = .{
                .execution_id = completion.execution_id,
                .package_index = stored.package_index,
                .plugin_id = stored.plugin_id,
                .digest = stored.digest,
                .batch = &stored.batch,
            },
        }
    else |err|
        .{
            .failed = .{
                .execution_id = completion.execution_id,
                .reason = err,
            },
        };

    const execution = client.model.plugins.finishPluginExecution(command.executionId()) orelse
        return reportPluginCompletion(client, .ignored);
    if (execution.configuration_generation != client.model.configuration_generation) {
        return reportPluginCompletion(client, .stale);
    }

    return reportPluginCompletion(client, switch (command) {
        .failed => |failure| .{
            .worker_failed = failure.reason,
        },
        .succeeded => |result| result: {
            authorizePluginResult(client.plugin_registry, result) catch |err| {
                break :result .{
                    .authorization_failed = err,
                };
            };

            _ = data.client_diagnostic.clear(&client.model);
            const disposition = try applyPluginBatch(client, result.batch);
            break :result switch (disposition) {
                .continue_client => .applied,
                .exit_client => .exit,
            };
        },
    });
}

/// Reads one bounded catalog page from the adopted generation. Example: `try plugin_queries.list(client, reply);`
pub fn listPlugins(client: *Client, reply: *core.ClientCommand) !void {
    const generation = client.lua_generation orelse return error.ConfigurationNotLoaded;
    if (reply.target_id != 0 and reply.target_id != generation.number) {
        return error.StaleConfiguration;
    }

    const registry = client.plugin_registry orelse return error.PluginRegistryUnavailable;
    const catalog: ConfiguredPlugins = .{
        .snapshot = &generation.snapshot,
        .registry = registry,
    };
    const index = std.math.cast(usize, reply.value) orelse return error.InvalidPage;
    const count = generation.snapshot.plugin_count;
    if (index > count) {
        return error.InvalidPage;
    }

    var writer = std.Io.Writer.fixed(&reply.bytes);
    try writer.print(
        "{{\"generation\":{d},\"entries\":[",
        .{
            generation.number,
        },
    );
    if (index < count) {
        const spec = &generation.snapshot.plugins[index];
        const package = catalog.package(index);
        try std.json.Stringify.value(
            .{
                .index = index,
                .path = spec.path(),
                .id = if (package) |loaded| loaded.manifest.id() else null,
                .version = if (package) |loaded| loaded.manifest.version() else null,
                .requested_enabled = client.reload.plugin_overrides.requested(spec.path()) orelse spec.enabled,
                .enabled = spec.enabled,
            },
            .{},
            &writer,
        );
    }

    try writer.writeAll("]}");
    reply.length = @intCast(writer.buffered().len);
    reply.value = if (index + 1 < count) @intCast(index + 1) else -1;
    reply.status = .applied;
}

/// Reads manifest metadata followed by individual action names. Example: `try plugin_queries.get(client, reply);`
pub fn describePlugin(client: *Client, reply: *core.ClientCommand) !void {
    const generation = client.lua_generation orelse return error.ConfigurationNotLoaded;
    if (reply.target_id != 0 and reply.target_id != generation.number) {
        return error.StaleConfiguration;
    }

    const registry = client.plugin_registry orelse return error.PluginRegistryUnavailable;
    const catalog: ConfiguredPlugins = .{
        .snapshot = &generation.snapshot,
        .registry = registry,
    };
    const index = try catalog.find(reply.text());
    const spec = &generation.snapshot.plugins[index];
    const package = catalog.package(index);
    const page = std.math.cast(usize, reply.value) orelse return error.InvalidPage;
    const action_count: usize = if (package) |loaded| loaded.manifest.action_count else 0;
    if (page > action_count) {
        return error.InvalidPage;
    }

    var writer = std.Io.Writer.fixed(&reply.bytes);
    try writer.print(
        "{{\"generation\":{d},\"entries\":[",
        .{
            generation.number,
        },
    );
    if (page == 0) {
        if (package) |loaded| {
            var capabilities: [std.meta.fields(core.Capability).len][]const u8 = undefined;
            var count: usize = 0;
            var iterator = loaded.manifest.capabilities.iterator();
            while (iterator.next()) |capability| {
                capabilities[count] = capability.canonicalName();
                count += 1;
            }

            const digest = std.fmt.bytesToHex(loaded.digest, .lower);
            try std.json.Stringify.value(
                .{
                    .path = spec.path(),
                    .requested_enabled = client.reload.plugin_overrides.requested(spec.path()) orelse spec.enabled,
                    .enabled = spec.enabled,
                    .id = loaded.manifest.id(),
                    .version = loaded.manifest.version(),
                    .entry = loaded.manifest.entry(),
                    .source = loaded.manifest.source(),
                    .revision = loaded.manifest.revision(),
                    .digest = digest[0..],
                    .capabilities = capabilities[0..count],
                },
                .{},
                &writer,
            );
        } else {
            try std.json.Stringify.value(
                .{
                    .path = spec.path(),
                    .requested_enabled = client.reload.plugin_overrides.requested(spec.path()) orelse spec.enabled,
                    .enabled = spec.enabled,
                    .id = @as(?[]const u8, null),
                },
                .{},
                &writer,
            );
        }
    } else {
        try std.json.Stringify.value(
            package.?.manifest.actions[page - 1].slice(),
            .{},
            &writer,
        );
    }

    try writer.writeAll("]}");
    reply.length = @intCast(writer.buffered().len);
    reply.value = if (page < action_count) @intCast(page + 1) else -1;
    reply.status = .applied;
}

pub fn setPluginEnabled(client: *Client, reply: *core.ClientCommand, enabled: bool) !void {
    const generation = client.lua_generation orelse return error.ConfigurationNotLoaded;
    const registry = client.plugin_registry orelse return error.PluginRegistryUnavailable;
    if (client.options.config_path == null or client.options.trust_path == null) {
        return error.ConfigurationNotLoaded;
    }

    const catalog: ConfiguredPlugins = .{
        .snapshot = &generation.snapshot,
        .registry = registry,
    };
    const index = try catalog.find(reply.text());
    var override: data.PluginOverride = .{
        .spec = generation.snapshot.plugins[index],
    };
    override.spec.enabled = enabled;
    if (catalog.package(index)) |package| {
        override.plugin_id = core.stableId(package.manifest.id());
    }

    try client.reload.plugin_overrides.set(override);
    client.reload.force_next = true;
    reply.status = .admitted;
}

/// Schedules an existing declared action with normal capability checks. Example: `try plugin_invocations.run(client, reply);`
pub fn runPluginCommand(client: *Client, reply: *core.ClientCommand) !void {
    const generation = client.lua_generation orelse return error.ConfigurationNotLoaded;
    const registry = client.plugin_registry orelse return error.PluginRegistryUnavailable;
    const catalog: ConfiguredPlugins = .{
        .snapshot = &generation.snapshot,
        .registry = registry,
    };
    const index = try catalog.find(reply.text());
    const package = catalog.package(index) orelse return error.PluginDisabled;
    const requested: data.PluginAction = .{
        .plugin = core.stableId(package.manifest.id()),
        .action = reply.target_id,
    };
    _ = try registry.resolve(requested);
    switch (try startPluginAction(client, requested, data.plugin_action.callbackContext(&client.model))) {
        .started => reply.status = .admitted,
        .busy => return error.PluginWorkerBusy,
        .unavailable => return error.PluginWorkerUnavailable,
        .rejected => |err| return err,
    }
}

/// Resolves one configured action and schedules its work outside the input path.
pub fn startPluginAction(client: *Client, requested: data.PluginAction, callback_context: data.CallbackContext) !plugin_action.StartOutcome {
    if (client.model.plugins.pluginExecution() != null) {
        return reportPluginStart(client, .busy);
    }

    const registry = client.plugin_registry orelse return reportPluginStart(client, .unavailable);
    const invocation = registry.resolve(requested) catch |err| switch (err) {
        error.PluginNotConfigured, error.UnknownPluginAction => return reportPluginStart(
            client,
            .{
                .rejected = err,
            },
        ),
    };
    var request = registry.workerRequest(invocation, callback_context) catch |err| switch (err) {
        error.PluginNotConfigured, error.UnknownPluginAction => return reportPluginStart(
            client,
            .{
                .rejected = err,
            },
        ),
    };
    request.executable = client.options.telar_executable;
    const execution = (try data.plugin_action.beginExecution(&client.model)) orelse
        return reportPluginStart(client, .busy);
    {
        errdefer {
            const rolled_back = client.model.plugins.finishPluginExecution(execution.id);
            std.debug.assert(rolled_back != null);
        }

        try client.to_background.push(.{ .plugin = .{
            .execution_id = execution.id,
            .request = request,
            .result = &client.plugin_result,
        } });
    }

    return reportPluginStart(
        client,
        .{
            .started = execution,
        },
    );
}

fn reportPluginStart(client: *Client, outcome: plugin_action.StartOutcome) !plugin_action.StartOutcome {
    if (plugin_action_delivery.startFailurePublication(outcome)) |failure| {
        try publishPluginFailure(client, failure);
    }
    return outcome;
}

fn authorizePluginResult(active_registry: ?*Registry, result: data.PluginResult) !void {
    const registry = active_registry orelse return error.PluginRegistryUnavailable;

    try registry.authorizeBatch(
        .{
            .package_index = result.package_index,
            .plugin_id = result.plugin_id,
            .digest = result.digest,
            .batch = result.batch,
        },
    );
}

fn applyPluginBatch(client: *Client, batch: *const data.EffectBatch) !plugin_action.BatchDisposition {
    for (batch.slice()) |effect| {
        if (try actions.executeAction(client, effect, .effect) == .stop) {
            return .exit_client;
        }
    }

    return .continue_client;
}

fn reportPluginCompletion(client: *Client, outcome: plugin_action.CompletionOutcome) !bool {
    if (plugin_action_delivery.completionFailurePublication(outcome)) |failure| {
        try publishPluginFailure(client, failure);
    }
    return outcome == .exit;
}

fn publishPluginFailure(client: *Client, failure: data.FailurePublication) !void {
    _ = try client_diagnostic.replace(
        &client.model,
        .{
            .diagnostic = failure.diagnostic,
        },
    );
    try notifications.publishNotificationNow(
        client,
        .{
            .level = .failure,
            .title = failure.title,
            .message = data.client_diagnostic.shown(&client.model) orelse return error.ClientDiagnosticMissing,
            .duration_ns = 7 * std.time.ns_per_s,
        },
    );
}
