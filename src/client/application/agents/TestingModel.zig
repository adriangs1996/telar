const ModelType = @import("../../model/Model.zig");
const AgentKeyType = @import("../../agents/AgentKey.zig");
const TabLocationType = @import("telar-core").TabLocation;
const std = @import("std");
const TestingModel = @This();

model: *ModelType,
local_key: AgentKeyType,
remote_key: AgentKeyType,
second: TabLocationType,

pub fn init() !TestingModel {
    const model = try std.testing.allocator.create(ModelType);
    errdefer std.testing.allocator.destroy(model);
    model.* = ModelType.init(std.testing.allocator, true);
    errdefer model.deinit();
    const first: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const second: TabLocationType = .{
        .workspace = first.workspace,
        .tab_id = @enumFromInt(2),
    };
    const local_key: AgentKeyType = .{
        .pane_id = @enumFromInt(2),
        .pane_generation = 1,
    };
    const remote_key: AgentKeyType = .{
        .pane_id = @enumFromInt(9),
        .pane_generation = 3,
    };
    try model.workspace.bootstrap(.{ .pane_id = @enumFromInt(1), .location = first, .size = .{ .cols = 20, .rows = 5 } });
    _ = try model.workspace.addCreated(.{
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = local_key.pane_id,
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(model.workspace.select(first.tab_id));
    _ = try model.reconcileAgentSnapshot(.{
        .revision = 1,
        .agents = &.{
            .{
                .key = local_key,
                .location = second,
                .pane_index = 1,
                .provider = .codex,
                .status = .working,
            },
            .{
                .key = remote_key,
                .location = .{
                    .workspace = .{ .workspace = @enumFromInt(3) },
                    .tab_id = @enumFromInt(6),
                },
                .pane_index = 2,
                .provider = .claude,
                .status = .ready,
            },
        },
    });

    return .{
        .model = model,
        .local_key = local_key,
        .remote_key = remote_key,
        .second = second,
    };
}

pub fn deinit(testing: *TestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}
