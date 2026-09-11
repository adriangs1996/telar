//! Request-scoped controller for bounded history imports.

const std = @import("std");
const core = @import("telar-core");
const history_mod = @import("../../../history/root.zig");
const delivery_mod = @import("../../delivery/root.zig");

pub const schema = core.schema;
pub const ResponseQueue = delivery_mod.ResponseQueue;

pub const Controller = @import("ImportHistoryController.zig");

test "Controller acknowledges an accepted batch" {
    const gpa = std.testing.allocator;
    var responses: ResponseQueue = .{};
    var service = try history_mod.Service.init(gpa, .{ .database_path = ":memory:" });
    defer {
        service.stop(std.testing.io);
        service.deinit(std.testing.io);
    }
    var controller = Controller.init(&responses, &service);

    var buffer: [512]u8 = undefined;
    const entries = [_]schema.ImportEntry{
        .{ .started_at_ms = 1_000, .command = "git status" },
    };
    const encoded = try schema.encodeImportHistory(&buffer, .{
        .request_id = @enumFromInt(5),
        .source = "zsh:/tmp/histfile",
        .base_sequence = 0,
        .entries = &entries,
    });
    const view = (try schema.decodeClient(encoded)).import_history;

    try controller.importHistory(std.testing.io, view);

    try std.testing.expectEqual(@as(u64, 5), @intFromEnum(responses.items[0].request_completed.request_id));
}
