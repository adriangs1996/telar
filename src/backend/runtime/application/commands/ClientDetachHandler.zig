const std = @import("std");
const Store = @import("../../client/Store.zig");
const Session = @import("../../client/Session.zig");
const ClientKey = @import("../../../history/ClientKey.zig");
const Effects = @import("ClientDetachEffects.zig");
const Handler = @This();

clients: *Store,
effects: Effects,

/// Drops UI resources while runtime-owned processes remain alive. Example: `try handler.execute(target);`
pub fn execute(self: *Handler, target: ClientKey) !void {
    const client = self.clients.resolve(target) orelse return error.ClientNotFound;
    if (client.closing or client.role != .ui or client.delivery.client_identity == .invalid) {
        return error.ClientNotFound;
    }

    self.effects.drop(self.effects.context, target);
}

test "client teardown rejects reused generations and observers before effects" {
    const Capture = struct {
        called: bool = false,
        fn drop(raw: *anyopaque, target: ClientKey) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(target.id == 7 and target.generation == 9);
            self.called = true;
        }
    };
    var capture: Capture = .{};
    var session: Session = undefined;
    session.key = .{ .id = 7, .generation = 9 };
    session.role = .ui;
    session.closing = false;
    session.delivery.client_identity = @enumFromInt(11);
    var clients: Store = .{};
    clients.items[0] = &session;
    var handler: Handler = .{ .clients = &clients, .effects = .{ .context = &capture, .drop = Capture.drop } };
    try std.testing.expectError(error.ClientNotFound, handler.execute(.{ .id = 7, .generation = 8 }));
    try std.testing.expect(!capture.called);
    session.role = .control;
    try std.testing.expectError(error.ClientNotFound, handler.execute(session.key));
    try std.testing.expect(!capture.called);
    session.role = .ui;
    try handler.execute(session.key);
    try std.testing.expect(capture.called);
}
