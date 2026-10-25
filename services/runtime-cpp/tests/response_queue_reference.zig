const std = @import("std");
const core = @import("telar-core");
const Queue = @import("src/backend/runtime/delivery/ResponseQueue.zig");
const QueryResult = @import("src/backend/history/QueryResult.zig");
const PendingNotification = @import("src/backend/runtime/delivery/PendingNotification.zig");

const Operation = extern struct {
    kind: u32,
    value: u64,
};

export fn evaluate(operations: [*]const Operation, count: usize, output: [*]u8) usize {
    var queue: Queue = .{};
    defer queue.clear();
    const notification = PendingNotification.init(.{ .title = "Queue", .message = "Notice" });
    var written: usize = 0;

    for (operations[0..count]) |operation| {
        var accepted = true;
        var selected: u8 = 0;
        var identity: u64 = 0;
        var delivered: u8 = 0;
        switch (operation.kind) {
            0 => queue.push(.{ .request_completed = .{ .request_id = @enumFromInt(operation.value) } }) catch {
                accepted = false;
            },
            1 => {
                const result = std.heap.c_allocator.create(QueryResult) catch unreachable;
                result.* = .{
                    .request_id = @enumFromInt(operation.value),
                    .origin = .{ .client = .{ .id = 1, .generation = 1 }, .close_after_reply = false },
                    .entries = &.{},
                    .gpa = std.heap.c_allocator,
                };
                queue.push(.{ .history_result = result }) catch {
                    result.deinit();
                    accepted = false;
                };
            },
            2 => {
                if (queue.peekManagement() orelse queue.peekObservation()) |entry| {
                    switch (entry.response.*) {
                        .request_completed => |reply| {
                            selected = 1;
                            identity = @intFromEnum(reply.request_id);
                        },
                        .history_result => |reply| {
                            selected = 2;
                            identity = @intFromEnum(reply.request_id);
                            reply.deinit();
                        },
                        .notification => selected = 3,
                        .notification_shown => |reply| {
                            selected = 4;
                            identity = @intFromEnum(reply.request_id);
                            delivered = reply.delivered_clients;
                        },
                        else => unreachable,
                    }
                    queue.removeAt(entry.offset);
                }
            },
            3 => queue.clear(),
            4 => accepted = queue.pushNotification(notification),
            5 => {
                if (queue.reserveNotificationShown(@enumFromInt(operation.value))) |reply| {
                    reply.delivered_clients = @intFromBool(queue.pushNotification(notification));
                } else |_| {
                    accepted = false;
                }
            },
            else => unreachable,
        }

        output[written] = @intFromBool(accepted);
        output[written + 1] = queue.len;
        output[written + 2] = queue.high_water;
        output[written + 3] = selected;
        output[written + 4] = delivered;
        std.mem.writeInt(u64, output[written + 5 ..][0..8], queue.dropped, .little);
        std.mem.writeInt(u64, output[written + 13 ..][0..8], identity, .little);
        written += 21;
    }
    return written;
}
