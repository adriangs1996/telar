//! Bounded client replica of the runtime's currently open agents.
//!
//! The runtime owns agent truth. This capability owns one immutable client
//! copy so application decisions and presentation read the same revision.

const std = @import("std");
const AgentInput = @import("AgentInput.zig");
const Snapshot = @import("AgentSnapshot.zig");
const AgentProviderType = @import("telar-core").AgentProvider;

pub fn copyLabel(destination: []u8, source: []const u8) !u8 {
    if (source.len > destination.len) {
        return error.AgentLabelTooLong;
    }
    if (!std.unicode.utf8ValidateSlice(source)) {
        return error.InvalidAgentLabel;
    }

    for (source) |byte| {
        if (byte < 0x20 or byte == 0x7f) {
            return error.InvalidAgentLabel;
        }
    }

    @memcpy(destination[0..source.len], source);
    return @intCast(source.len);
}

fn testingAgent() AgentInput {
    return .{
        .key = .{ .pane_id = @enumFromInt(7), .pane_generation = 2 },
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        },
        .pane_index = 1,
        .workspace_label = "telar",
        .tab_label = "main",
        .session_title = "Improve sidebar",
        .title_source = .generated,
        .title_state = .ready,
        .cwd_label = "~/sandbox/telar",
        .provider = .codex,
        .status = .working,
    };
}

test "snapshots own current agents and ignore stale replacement" {
    var snapshot: Snapshot = .{};
    const agent = testingAgent();

    try std.testing.expect(try snapshot.replace(.{ .revision = 4, .agents = &.{agent} }));
    try std.testing.expectEqual(AgentProviderType.codex, snapshot.slice()[0].provider);
    try std.testing.expectEqualStrings("Improve sidebar", snapshot.slice()[0].sessionTitle());
    try std.testing.expect(!try snapshot.replace(.{ .revision = 3, .agents = &.{} }));
    try std.testing.expectEqual(@as(u8, 1), snapshot.count);
}

test "snapshot owns every display label" {
    var snapshot: Snapshot = .{};
    var title = [_]u8{ 'f', 'i', 'r', 's', 't' };
    var agent = testingAgent();
    agent.session_title = &title;

    _ = try snapshot.replace(.{ .revision = 1, .agents = &.{agent} });
    title[0] = 'x';

    try std.testing.expectEqualStrings("first", snapshot.slice()[0].sessionTitle());
}

test "rejected replacement preserves the complete previous snapshot" {
    var snapshot: Snapshot = .{};
    const agent = testingAgent();
    _ = try snapshot.replace(.{ .revision = 1, .agents = &.{agent} });
    var invalid = agent;
    invalid.session_title = "broken\nlabel";

    try std.testing.expectError(error.InvalidAgentLabel, snapshot.replace(.{
        .revision = 2,
        .agents = &.{invalid},
    }));

    try std.testing.expectEqual(@as(u64, 1), snapshot.revision);
    try std.testing.expectEqualDeep(agent.key, snapshot.slice()[0].key);
    try std.testing.expectEqualStrings(agent.session_title, snapshot.slice()[0].sessionTitle());
}

test "duplicate agent generations are rejected" {
    var snapshot: Snapshot = .{};
    const agent = testingAgent();

    try std.testing.expectError(error.DuplicateAgent, snapshot.replace(.{
        .revision = 1,
        .agents = &.{ agent, agent },
    }));
}

test "pane lookup is scoped to its tab and exact generation" {
    var snapshot: Snapshot = .{};
    const agent = testingAgent();
    _ = try snapshot.replace(.{ .revision = 1, .agents = &.{agent} });

    try std.testing.expectEqualDeep(agent.key, snapshot.keyForPane(agent.location, agent.key.pane_id).?);
    try std.testing.expect(snapshot.keyForPane(.{
        .workspace = agent.location.workspace,
        .tab_id = @enumFromInt(3),
    }, agent.key.pane_id) == null);
    try std.testing.expect(snapshot.find(.{
        .pane_id = agent.key.pane_id,
        .pane_generation = agent.key.pane_generation + 1,
    }) == null);
}

test "working state is queried without mutating the replica" {
    var snapshot: Snapshot = .{};
    var agent = testingAgent();
    _ = try snapshot.replace(.{ .revision = 1, .agents = &.{agent} });
    const revision = snapshot.revision;

    try std.testing.expect(snapshot.hasWorkingAgent());
    try std.testing.expectEqual(revision, snapshot.revision);

    agent.status = .ready;
    _ = try snapshot.replace(.{ .revision = 2, .agents = &.{agent} });
    try std.testing.expect(!snapshot.hasWorkingAgent());
}
