//! Application policy for one synchronous, bounded client Lua action.

const EffectBatch = @import("../../config/EffectBatch.zig");
const Failure = @import("Failure.zig");
const Diagnostic = @import("../../config/Diagnostic.zig");
const action_module = @import("../../input/action.zig");

pub const Command = @import("../../types/LuaActionCommand.zig").LuaActionCommand;

pub const Invocation = @import("../../types/LuaInvocation.zig").LuaInvocation;

pub const Validation = @import("../../types/LuaValidation.zig").LuaValidation;

pub const Disposition = @import("../../types/LuaDisposition.zig").LuaDisposition;

pub const Outcome = @import("../../types/LuaActionOutcome.zig").LuaActionOutcome;

fn diagnosticFailure(reason: anyerror, message: []const u8) Failure {
    var diagnostic: Diagnostic = .{};
    diagnostic.set(
        "{s}",
        .{
            message,
        },
    );
    return .{
        .reason = reason,
        .diagnostic = diagnostic,
    };
}

fn callbackInvocation(effects: []const action_module.Action) Invocation {
    var batch: EffectBatch = .{};
    for (effects, 0..) |effect, index| {
        batch.items[index] = effect;
    }

    batch.len = @intCast(effects.len);
    return .{
        .callback = batch,
    };
}
