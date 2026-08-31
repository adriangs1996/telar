//! Application policy for one synchronous, bounded client Lua action.

const std = @import("std");
const core = @import("telar-core");
const lua_config = @import("../../config/root.zig");
const input = @import("../../input/root.zig");
const client_model = @import("../model.zig");

const Action = input.action.Action;
const schema = core.schema;

pub const Command = union(enum) {
    callback: input.action.CallbackRef,
    expression: input.action.CallbackRef,
};

pub const Failure = struct {
    reason: anyerror,
    diagnostic: lua_config.Diagnostic,
};

pub const Invocation = union(enum) {
    callback: lua_config.EffectBatch,
    expression: lua_config.InputDecision,
    unavailable,
    failed: Failure,
};

pub const Validation = union(enum) {
    valid,
    failed: Failure,
};

pub const Disposition = enum {
    continue_client,
    exit_client,
};

pub const Outcome = union(enum) {
    applied,
    exit,
    input: lua_config.InputDecision,
    unavailable,
    invocation_failed: anyerror,
    validation_failed: anyerror,
};

pub const Effects = struct {
    context: *anyopaque,
    invoke: *const fn (*anyopaque, Command, lua_config.CallbackContext) Invocation,
    validate: *const fn (*anyopaque, *const lua_config.EffectBatch) Validation,
    apply: *const fn (*anyopaque, Action) anyerror!Disposition,
};

pub const LuaActionHandler = struct {
    model: *client_model.Model,
    effects: Effects,

    /// Evaluates one current Lua action and applies only a fully valid batch.
    ///
    /// ```zig
    /// const outcome = try handler.execute(command);
    /// ```
    pub fn execute(handler: *LuaActionHandler, command: Command) !Outcome {
        const invocation = handler.effects.invoke(
            handler.effects.context,
            command,
            handler.model.callbackContext(),
        );

        return switch (invocation) {
            .unavailable => .unavailable,
            .failed => |failure| failed: {
                try handler.publishFailure(failure);
                break :failed .{ .invocation_failed = failure.reason };
            },
            .expression => |decision| expression: {
                _ = handler.model.clearDiagnostic();
                break :expression .{ .input = decision };
            },
            .callback => |batch| callback: {
                switch (handler.effects.validate(handler.effects.context, &batch)) {
                    .valid => {},
                    .failed => |failure| {
                        try handler.publishFailure(failure);
                        break :callback .{ .validation_failed = failure.reason };
                    },
                }

                _ = handler.model.clearDiagnostic();
                for (batch.slice()) |effect| {
                    if (try handler.effects.apply(handler.effects.context, effect) == .exit_client) {
                        break :callback .exit;
                    }
                }

                break :callback .applied;
            },
        };
    }

    fn publishFailure(handler: *LuaActionHandler, failure: Failure) !void {
        _ = handler.model.replaceDiagnostic(failure.diagnostic) catch |err| switch (err) {
            error.InvalidClientDiagnostic => try handler.model.setDiagnostic(
                "Lua action failed: {s}",
                .{@errorName(failure.reason)},
            ),
        };
    }
};

const Capture = struct {
    invocation: Invocation,
    validation: Validation = .valid,
    invoke_calls: usize = 0,
    validate_calls: usize = 0,
    apply_calls: usize = 0,
    exit_after: ?usize = null,
    observed_context: lua_config.CallbackContext = undefined,
    diagnostic_cleared_before_apply: bool = true,
    model: *const client_model.Model,
    applied: [lua_config.max_callback_effects]Action = undefined,

    fn port(capture: *Capture) Effects {
        return .{
            .context = capture,
            .invoke = invoke,
            .validate = validate,
            .apply = apply,
        };
    }

    fn invoke(raw_context: *anyopaque, command: Command, context: lua_config.CallbackContext) Invocation {
        const capture: *Capture = @ptrCast(@alignCast(raw_context));
        _ = command;
        capture.invoke_calls += 1;
        capture.observed_context = context;
        return capture.invocation;
    }

    fn validate(raw_context: *anyopaque, batch: *const lua_config.EffectBatch) Validation {
        const capture: *Capture = @ptrCast(@alignCast(raw_context));
        _ = batch;
        capture.validate_calls += 1;
        return capture.validation;
    }

    fn apply(raw_context: *anyopaque, effect: Action) !Disposition {
        const capture: *Capture = @ptrCast(@alignCast(raw_context));
        capture.diagnostic_cleared_before_apply = capture.diagnostic_cleared_before_apply and
            capture.model.diagnostic() == null;
        capture.applied[capture.apply_calls] = effect;
        capture.apply_calls += 1;
        if (capture.exit_after) |index| {
            if (capture.apply_calls == index) {
                return .exit_client;
            }
        }

        return .continue_client;
    }
};

fn diagnosticFailure(reason: anyerror, message: []const u8) Failure {
    var diagnostic: lua_config.Diagnostic = .{};
    diagnostic.set("{s}", .{message});
    return .{ .reason = reason, .diagnostic = diagnostic };
}

fn callbackInvocation(effects: []const Action) Invocation {
    var batch: lua_config.EffectBatch = .{};
    for (effects, 0..) |effect, index| {
        batch.items[index] = effect;
    }

    batch.len = @intCast(effects.len);
    return .{ .callback = batch };
}

test "LuaActionHandler validates the whole callback before ordered application" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const pane_id = @as(schema.PaneId, @enumFromInt(7));
    try model.workspace.bootstrap(pane_id, .{
        .workspace = .{ .workspace = @enumFromInt(2) },
        .tab_id = @enumFromInt(3),
    }, .{ .cols = 20, .rows = 5 });
    _ = try model.setDiagnostic("old failure", .{});
    const effects = [_]Action{ .toggle_sidebar, .new_tab, .close_tab };
    var capture: Capture = .{
        .invocation = callbackInvocation(&effects),
        .exit_after = 2,
        .model = &model,
    };
    var handler: LuaActionHandler = .{ .model = &model, .effects = capture.port() };

    const outcome = try handler.execute(.{ .callback = .{ .generation = 1, .id = 2 } });

    try std.testing.expect(outcome == .exit);
    try std.testing.expectEqual(@as(usize, 1), capture.invoke_calls);
    try std.testing.expectEqual(@as(usize, 1), capture.validate_calls);
    try std.testing.expectEqual(@as(usize, 2), capture.apply_calls);
    try std.testing.expect(capture.diagnostic_cleared_before_apply);
    try std.testing.expectEqualSlices(Action, effects[0..2], capture.applied[0..capture.apply_calls]);
    try std.testing.expectEqual(@as(u16, 1), capture.observed_context.tab_count);
    try std.testing.expectEqual(@intFromEnum(pane_id), capture.observed_context.focused_pane_id);
    try std.testing.expect(model.diagnostic() == null);
}

test "LuaActionHandler publishes invocation failure without validation or effects" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: Capture = .{
        .invocation = .{ .failed = diagnosticFailure(error.LuaCallbackFailed, "callback exploded") },
        .model = &model,
    };
    var handler: LuaActionHandler = .{ .model = &model, .effects = capture.port() };

    const outcome = try handler.execute(.{ .callback = .{ .generation = 1, .id = 2 } });

    try std.testing.expectEqual(error.LuaCallbackFailed, outcome.invocation_failed);
    try std.testing.expectEqualStrings("callback exploded", model.diagnostic().?);
    try std.testing.expectEqual(client_model.Version{ .diagnostic = 1 }, model.version());
    try std.testing.expectEqual(@as(usize, 0), capture.validate_calls);
    try std.testing.expectEqual(@as(usize, 0), capture.apply_calls);
}

test "LuaActionHandler replaces invalid failure text with a safe diagnostic" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var invalid: lua_config.Diagnostic = .{};
    invalid.buffer[0] = 0xff;
    invalid.len = 1;
    var capture: Capture = .{
        .invocation = .{ .failed = .{
            .reason = error.MalformedLuaDiagnostic,
            .diagnostic = invalid,
        } },
        .model = &model,
    };
    var handler: LuaActionHandler = .{ .model = &model, .effects = capture.port() };

    const outcome = try handler.execute(.{ .callback = .{ .generation = 1, .id = 2 } });

    try std.testing.expectEqual(error.MalformedLuaDiagnostic, outcome.invocation_failed);
    try std.testing.expectEqualStrings("Lua action failed: MalformedLuaDiagnostic", model.diagnostic().?);
}

test "LuaActionHandler rejects an invalid callback batch before its first effect" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const effects = [_]Action{.toggle_sidebar};
    var capture: Capture = .{
        .invocation = callbackInvocation(&effects),
        .validation = .{ .failed = diagnosticFailure(error.UnknownPluginAction, "invalid plugin action") },
        .model = &model,
    };
    var handler: LuaActionHandler = .{ .model = &model, .effects = capture.port() };

    const outcome = try handler.execute(.{ .callback = .{ .generation = 1, .id = 2 } });

    try std.testing.expectEqual(error.UnknownPluginAction, outcome.validation_failed);
    try std.testing.expectEqualStrings("invalid plugin action", model.diagnostic().?);
    try std.testing.expectEqual(@as(usize, 1), capture.validate_calls);
    try std.testing.expectEqual(@as(usize, 0), capture.apply_calls);
}

test "LuaActionHandler returns semantic input and leaves unavailable actions untouched" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    _ = try model.setDiagnostic("old failure", .{});
    var capture: Capture = .{
        .invocation = .{ .expression = .consume },
        .model = &model,
    };
    var handler: LuaActionHandler = .{ .model = &model, .effects = capture.port() };

    const input_outcome = try handler.execute(.{ .expression = .{ .generation = 1, .id = 2 } });

    try std.testing.expect(input_outcome.input == .consume);
    try std.testing.expect(model.diagnostic() == null);
    try std.testing.expectEqual(@as(usize, 0), capture.validate_calls);
    try std.testing.expectEqual(@as(usize, 0), capture.apply_calls);

    _ = try model.setDiagnostic("preserved", .{});
    capture.invocation = .unavailable;
    const unavailable = try handler.execute(.{ .callback = .{ .generation = 1, .id = 2 } });

    try std.testing.expect(unavailable == .unavailable);
    try std.testing.expectEqualStrings("preserved", model.diagnostic().?);
}
