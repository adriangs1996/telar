//! Application policy for one synchronous, bounded client Lua action.

const CallbackRefType = @import("../../input/CallbackRef.zig");
const EffectBatchType = @import("../../config/EffectBatch.zig");
const effects_module = @import("../../config/effects.zig");
const Failure = @import("Failure.zig");
const DiagnosticType = @import("../../config/Diagnostic.zig");
const action_module = @import("../../input/action.zig");
const std = @import("std");

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
