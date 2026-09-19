const core = @import("telar-core");
const std = @import("std");
const Session = @import("../../client/Session.zig");
const Store = @import("../../client/Store.zig");
const Handler = @This();

clients: *const Store,

/// Snapshots active interactive connections without retaining them. Example: `const list = handler.execute();`
pub fn execute(self: *const Handler) core.ClientList {
    var result: core.ClientList = .{ .request_id = .none };
    for (self.clients.items) |slot| {
        const client = slot orelse continue;
        if (client.closing or client.role != .ui or client.delivery.client_identity == .invalid) {
            continue;
        }

        result.entries[result.count] = .{
            .id = client.key.id,
            .generation = client.key.generation,
            .identity = @intFromEnum(client.delivery.client_identity),
            .attachments = @intCast(client.attachments.count),
            .last_input_pane = core.raw(client.last_input_pane),
            .last_input_sequence = client.last_input_sequence,
        };
        result.count += 1;
    }

    return result;
}

test "client discovery excludes observers closing sessions and unregistered connections" {
    var session: Session = undefined;
    session.key = .{ .id = 7, .generation = 9 };
    session.role = .ui;
    session.closing = false;
    session.delivery.client_identity = @enumFromInt(11);
    session.attachments.count = 2;
    session.last_input_pane = @enumFromInt(5);
    session.last_input_sequence = 12;
    var store: Store = .{};
    store.items[0] = &session;
    var handler: Handler = .{ .clients = &store };
    const list = handler.execute();
    try std.testing.expectEqual(@as(u8, 1), list.count);
    try std.testing.expectEqual(@as(u64, 9), list.entries[0].generation);
    session.role = .control;
    try std.testing.expectEqual(@as(u8, 0), handler.execute().count);
    session.role = .ui;
    session.closing = true;
    try std.testing.expectEqual(@as(u8, 0), handler.execute().count);
    session.closing = false;
    session.delivery.client_identity = .invalid;
    try std.testing.expectEqual(@as(u8, 0), handler.execute().count);
}
