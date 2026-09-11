const ModelType = @import("../../model/Model.zig");
const BarUpdateCommand = @import("BarUpdateCommand.zig");
const bar_update = @import("bar_update.zig");
const ContentType = @import("../../bars/Content.zig");
const Failure = @import("Failure.zig");
const ClientDiagnosticHandlerType = @import("ClientDiagnosticHandler.zig");
const client_diagnostic = @import("client_diagnostic.zig");
const ApplyBarUpdateHandler = @This();

model: *ModelType,

/// Commits current content or publishes a bounded source diagnostic.
///
/// ```zig
/// const outcome = try handler.execute(command);
/// ```
pub fn execute(handler: *ApplyBarUpdateHandler, command: BarUpdateCommand) !bar_update.Outcome {
    return switch (command.result) {
        .content => |content| handler.commit(command, content),
        .failed => |failure| handler.publishFailure(command, failure),
    };
}

fn commit(handler: *ApplyBarUpdateHandler, command: BarUpdateCommand, content: ContentType) !bar_update.Outcome {
    const update_commit = handler.model.updateBar(.{
        .generation = command.generation,
        .position = command.position,
        .content = content,
    }) catch |err| switch (err) {
        error.StaleBarUpdate, error.InvalidBarUpdateTarget => return .stale,
    };

    return if (update_commit) |value| .{ .updated = value } else .unchanged;
}

fn publishFailure(handler: *ApplyBarUpdateHandler, command: BarUpdateCommand, failure: Failure) !bar_update.Outcome {
    const state = handler.model.barState();
    if (command.generation != handler.model.configurationGeneration() or
        state.layout.generation != command.generation or
        !state.layout.isLive(command.position))
    {
        return .stale;
    }

    var diagnostics: ClientDiagnosticHandlerType = .{ .model = handler.model };
    _ = try diagnostics.replace(.{
        .diagnostic = failure.diagnostic,
        .invalid_fallback = client_diagnostic.formatted(
            "bar source failed: {s}",
            .{@errorName(failure.reason)},
        ),
    });

    return .{ .failed = failure.reason };
}
