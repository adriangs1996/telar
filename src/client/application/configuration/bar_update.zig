//! Application policy for one configured bar-source result.

const ContentType = @import("../../bars/Content.zig");
const Failure = @import("Failure.zig");
const BarUpdateCommitType = @import("../../model/BarUpdateCommit.zig");
const ConfigurationType = @import("../../bars/Configuration.zig");
const std = @import("std");
const ModelType = @import("../../model/Model.zig");
const ApplyBarUpdateHandler = @import("ApplyBarUpdateHandler.zig");
const DiagnosticType = @import("../../config/Diagnostic.zig");
const VersionType = @import("../../model/Version.zig");

pub const Result = union(enum) {
    content: ContentType,
    failed: Failure,
};

pub const Outcome = union(enum) {
    updated: BarUpdateCommitType,
    unchanged,
    stale,
    failed: anyerror,
};

fn contentWith(text: []const u8) ContentType {
    var content: ContentType = .{};
    content.append(.{ .text = text }) catch unreachable;

    return content;
}

test "ApplyBarUpdateHandler folds equal content and rejects stale results quietly" {
    const configuration: ConfigurationType = .{
        .bottom = .{
            .{ .dynamic = .{ .callback = .{ .generation = 2, .id = 0 }, .interval_ns = std.time.ns_per_s } },
            .empty,
            .tabs,
        },
    };
    var model = ModelType.initWithState(std.testing.allocator, .{
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
    const configuration: ConfigurationType = .{
        .bottom = .{
            .{ .dynamic = .{ .callback = .{ .generation = 2, .id = 0 }, .interval_ns = std.time.ns_per_s } },
            .empty,
            .tabs,
        },
    };
    var model = ModelType.initWithState(std.testing.allocator, .{
        .pane_gaps = true,
        .configuration_generation = 2,
        .bars = configuration.presentation(),
    });
    defer model.deinit();
    var handler: ApplyBarUpdateHandler = .{ .model = &model };
    var diagnostic: DiagnosticType = .{};
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
    try std.testing.expectEqual(VersionType{ .diagnostic = 1 }, model.version());
}
