const ApplyBarUpdateHandler = @This();
const client_model = @import("../../root.zig").model;
const Command = @import("BarUpdateCommand.zig");
const source_namespace = @import("bar_update.zig");
const bars = @import("../../bars/root.zig");
const Failure = @import("Failure.zig");
const client_diagnostic = @import("client_diagnostic.zig");
model: *client_model.Model,

/// Commits current content or publishes a bounded source diagnostic.
///
/// ```zig
/// const outcome = try handler.execute(command);
/// ```
pub fn execute(handler: *ApplyBarUpdateHandler, command: Command) !source_namespace.Outcome {
    return switch (command.result) {
        .content => |content| handler.commit(command, content),
        .failed => |failure| handler.publishFailure(command, failure),
    };
}

fn commit(handler: *ApplyBarUpdateHandler, command: Command, content: bars.Content) !source_namespace.Outcome {
    const update_commit = handler.model.updateBar(.{
        .generation = command.generation,
        .position = command.position,
        .content = content,
    }) catch |err| switch (err) {
        error.StaleBarUpdate, error.InvalidBarUpdateTarget => return .stale,
    };

    return if (update_commit) |value| .{ .updated = value } else .unchanged;
}

fn publishFailure(handler: *ApplyBarUpdateHandler, command: Command, failure: Failure) !source_namespace.Outcome {
    const state = handler.model.barState();
    if (command.generation != handler.model.configurationGeneration() or
        state.layout.generation != command.generation or
        !state.layout.isLive(command.position))
    {
        return .stale;
    }

    var diagnostics: client_diagnostic.ClientDiagnosticHandler = .{ .model = handler.model };
    _ = try diagnostics.replace(.{
        .diagnostic = failure.diagnostic,
        .invalid_fallback = client_diagnostic.formatted(
            "bar source failed: {s}",
            .{@errorName(failure.reason)},
        ),
    });

    return .{ .failed = failure.reason };
}
