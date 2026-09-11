//! Application policy for one synchronous, bounded client Lua action.

const CallbackRefType = @import("../../input/CallbackRef.zig");
const EffectBatchType = @import("../../config/EffectBatch.zig");
const effects_module = @import("../../config/effects.zig");
const Failure = @import("Failure.zig");
const DiagnosticType = @import("../../config/Diagnostic.zig");
const action_module = @import("../../input/action.zig");
const ModelType = @import("../../model/Model.zig");
const std = @import("std");
const PaneIdType = @import("telar-core").PaneId;
const LuaActionCapture = @import("LuaActionCapture.zig");
const LuaActionHandler = @import("LuaActionHandler.zig");
const VersionType = @import("../../model/Version.zig");

pub const Command = union(enum) {
    callback: CallbackRefType,
    expression: CallbackRefType,
};

pub const Invocation = union(enum) {
    callback: EffectBatchType,
    expression: effects_module.InputDecision,
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
    input: effects_module.InputDecision,
    unavailable,
    invocation_failed: anyerror,
    validation_failed: anyerror,
};

fn diagnosticFailure(reason: anyerror, message: []const u8) Failure {
    var diagnostic: DiagnosticType = .{};
    diagnostic.set("{s}", .{message});
    return .{ .reason = reason, .diagnostic = diagnostic };
}

fn callbackInvocation(effects: []const action_module.Action) Invocation {
    var batch: EffectBatchType = .{};
    for (effects, 0..) |effect, index| {
        batch.items[index] = effect;
    }

    batch.len = @intCast(effects.len);
    return .{ .callback = batch };
}

test "LuaActionHandler validates the whole callback before ordered application" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    const pane_id = @as(PaneIdType, @enumFromInt(7));
    try model.workspace.bootstrap(.{ .pane_id = pane_id, .location = .{
        .workspace = .{ .workspace = @enumFromInt(2) },
        .tab_id = @enumFromInt(3),
    }, .size = .{ .cols = 20, .rows = 5 } });
    _ = try model.setDiagnostic("old failure", .{});
    const effects = [_]action_module.Action{ .toggle_sidebar, .new_tab, .close_tab };
    var capture: LuaActionCapture = .{
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
    try std.testing.expectEqualSlices(action_module.Action, effects[0..2], capture.applied[0..capture.apply_calls]);
    try std.testing.expectEqual(@as(u16, 1), capture.observed_context.tab_count);
    try std.testing.expectEqual(@intFromEnum(pane_id), capture.observed_context.focused_pane_id);
    try std.testing.expect(model.diagnostic() == null);
}

test "LuaActionHandler publishes invocation failure without validation or effects" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: LuaActionCapture = .{
        .invocation = .{ .failed = diagnosticFailure(error.LuaCallbackFailed, "callback exploded") },
        .model = &model,
    };
    var handler: LuaActionHandler = .{ .model = &model, .effects = capture.port() };

    const outcome = try handler.execute(.{ .callback = .{ .generation = 1, .id = 2 } });

    try std.testing.expectEqual(error.LuaCallbackFailed, outcome.invocation_failed);
    try std.testing.expectEqualStrings("callback exploded", model.diagnostic().?);
    try std.testing.expectEqual(VersionType{ .diagnostic = 1 }, model.version());
    try std.testing.expectEqual(@as(usize, 0), capture.validate_calls);
    try std.testing.expectEqual(@as(usize, 0), capture.apply_calls);
}

test "LuaActionHandler replaces invalid failure text with a safe diagnostic" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    var invalid: DiagnosticType = .{};
    invalid.buffer[0] = 0xff;
    invalid.len = 1;
    var capture: LuaActionCapture = .{
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
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    const effects = [_]action_module.Action{.toggle_sidebar};
    var capture: LuaActionCapture = .{
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
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    _ = try model.setDiagnostic("old failure", .{});
    var capture: LuaActionCapture = .{
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
