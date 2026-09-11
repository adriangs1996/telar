//! Application policy for one synchronous, bounded client Lua action.

const std = @import("std");
const core = @import("telar-core");
const lua_config = @import("../../config/root.zig");
const input = @import("../../input/root.zig");
const client_diagnostic = @import("../configuration/root.zig").client_diagnostic;
const client_model = @import("../../root.zig").model;

pub const Action = input.action.Action;
const schema = core.schema;

pub const Command = union(enum) {
    callback: input.action.CallbackRef,
    expression: input.action.CallbackRef,
};

pub const Failure = @import("Failure.zig");

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

pub const Effects = @import("LuaActionEffects.zig");

pub const LuaActionHandler = @import("LuaActionHandler.zig");

const Capture = @import("LuaActionCapture.zig");

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
    try model.workspace.bootstrap(.{ .pane_id = pane_id, .location = .{
        .workspace = .{ .workspace = @enumFromInt(2) },
        .tab_id = @enumFromInt(3),
    }, .size = .{ .cols = 20, .rows = 5 } });
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
