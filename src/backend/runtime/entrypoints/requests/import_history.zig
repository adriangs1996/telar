//! Request-scoped controller for bounded history imports.

const std = @import("std");
const ResponseQueue = @import("../../delivery/ResponseQueue.zig");
const ServiceType = @import("../../../history/Service.zig");
const ImportHistoryController = @import("ImportHistoryController.zig");
const ImportEntryType = @import("telar-core").ImportEntry;
const encodeImportHistory_module = @import("telar-core").encodeImportHistory;
const decodeClient_module = @import("telar-core").decodeClient;

test "Controller acknowledges an accepted batch" {
    const gpa = std.testing.allocator;
    var responses: ResponseQueue = .{};
    var service = try ServiceType.init(gpa, .{ .database_path = ":memory:" });
    defer {
        service.stop(std.testing.io);
        service.deinit(std.testing.io);
    }
    var controller = ImportHistoryController.init(&responses, &service);

    var buffer: [512]u8 = undefined;
    const entries = [_]ImportEntryType{
        .{ .started_at_ms = 1_000, .command = "git status" },
    };
    const encoded = try encodeImportHistory_module(&buffer, .{
        .request_id = @enumFromInt(5),
        .source = "zsh:/tmp/histfile",
        .base_sequence = 0,
        .entries = &entries,
    });
    const view = (try decodeClient_module(encoded)).import_history;

    try controller.importHistory(std.testing.io, view);

    try std.testing.expectEqual(@as(u64, 5), @intFromEnum(responses.items[0].request_completed.request_id));
}
