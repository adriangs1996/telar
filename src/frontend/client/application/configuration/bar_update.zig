//! Application policy for one configured bar-source result.

const std = @import("std");
const bars = @import("../../../bars/root.zig");
const lua_config = @import("../../../config/root.zig");
const client_diagnostic = @import("client_diagnostic.zig");
const client_model = @import("../../model/root.zig");

pub const Failure = struct {
    reason: anyerror,
    diagnostic: lua_config.Diagnostic,
};

pub const Result = union(enum) {
    content: bars.Content,
    failed: Failure,
};

pub const Command = struct {
    generation: u64,
    position: bars.Position,
    result: Result,
};

pub const Outcome = union(enum) {
    updated: client_model.BarUpdateCommit,
    unchanged,
    stale,
    failed: anyerror,
};

pub const ApplyBarUpdateHandler = struct {
    model: *client_model.Model,

    /// Commits current content or publishes a bounded source diagnostic.
    ///
    /// ```zig
    /// const outcome = try handler.execute(command);
    /// ```
    pub fn execute(handler: *ApplyBarUpdateHandler, command: Command) !Outcome {
        return switch (command.result) {
            .content => |content| handler.commit(command, content),
            .failed => |failure| handler.publishFailure(command, failure),
        };
    }

    fn commit(handler: *ApplyBarUpdateHandler, command: Command, content: bars.Content) !Outcome {
        const update_commit = handler.model.updateBar(.{
            .generation = command.generation,
            .position = command.position,
            .content = content,
        }) catch |err| switch (err) {
            error.StaleBarUpdate, error.InvalidBarUpdateTarget => return .stale,
        };

        return if (update_commit) |value| .{ .updated = value } else .unchanged;
    }

    fn publishFailure(handler: *ApplyBarUpdateHandler, command: Command, failure: Failure) !Outcome {
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
};

fn contentWith(text: []const u8) bars.Content {
    var content: bars.Content = .{};
    content.append(text, null, .{}) catch unreachable;

    return content;
}

test "ApplyBarUpdateHandler folds equal content and rejects stale results quietly" {
    const configuration: bars.Configuration = .{
        .bottom = .{
            .{ .dynamic = .{ .callback = .{ .generation = 2, .id = 0 }, .interval_ns = std.time.ns_per_s } },
            .empty,
            .tabs,
        },
    };
    var model = client_model.Model.initWithState(std.testing.allocator, .{
        .pane_gaps = true,
        .configuration_generation = 2,
        .bars = configuration.presentation(),
    });
    defer model.deinit();
    var handler: ApplyBarUpdateHandler = .{ .model = &model };

    try std.testing.expect((try handler.execute(.{
        .generation = 1,
        .position = .bottom_left,
        .result = .{ .content = contentWith("old") },
    })) == .stale);
    try std.testing.expect((try handler.execute(.{
        .generation = 2,
        .position = .bottom_left,
        .result = .{ .content = contentWith("ready") },
    })) == .updated);
    try std.testing.expect((try handler.execute(.{
        .generation = 2,
        .position = .bottom_left,
        .result = .{ .content = contentWith("ready") },
    })) == .unchanged);

    try std.testing.expectEqual(@as(u64, 1), model.version().bars);
}

test "ApplyBarUpdateHandler publishes bounded failures without replacing content" {
    const configuration: bars.Configuration = .{
        .bottom = .{
            .{ .dynamic = .{ .callback = .{ .generation = 2, .id = 0 }, .interval_ns = std.time.ns_per_s } },
            .empty,
            .tabs,
        },
    };
    var model = client_model.Model.initWithState(std.testing.allocator, .{
        .pane_gaps = true,
        .configuration_generation = 2,
        .bars = configuration.presentation(),
    });
    defer model.deinit();
    var handler: ApplyBarUpdateHandler = .{ .model = &model };
    var diagnostic: lua_config.Diagnostic = .{};
    diagnostic.set("clock callback failed", .{});

    try std.testing.expect((try handler.execute(.{
        .generation = 1,
        .position = .bottom_left,
        .result = .{ .failed = .{
            .reason = error.LuaBarCallbackFailed,
            .diagnostic = diagnostic,
        } },
    })) == .stale);
    try std.testing.expect(model.diagnostic() == null);

    const outcome = try handler.execute(.{
        .generation = 2,
        .position = .bottom_left,
        .result = .{ .failed = .{
            .reason = error.LuaBarCallbackFailed,
            .diagnostic = diagnostic,
        } },
    });

    try std.testing.expect(outcome == .failed);
    try std.testing.expectEqualStrings("clock callback failed", model.diagnostic().?);
    try std.testing.expectEqual(client_model.Version{ .diagnostic = 1 }, model.version());
}
