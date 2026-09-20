const core = @import("telar-core");
const Session = @import("../../client/Session.zig");
const Store = @import("../../client/Store.zig");
const Effects = @import("ClientCommandEffects.zig");
const Handler = @This();

clients: *Store,
effects: Effects,

/// Routes one bounded operation to the observed UI generation. Example: `try handler.request(session, command);`
pub fn request(self: *Handler, session: *Session, command: core.ClientCommand) !void {
    if (session.role != .control or command.status != .request or session.pending_client_command != null) {
        return error.InvalidClientCommand;
    }

    const target = self.clients.resolve(.{ .id = command.route.id, .generation = command.route.generation }) orelse return error.ClientNotFound;
    if (target.closing or target.role != .ui or target.delivery.client_identity == .invalid) {
        return error.ClientNotFound;
    }

    var routed = command;
    routed.route = .{ .id = session.key.id, .generation = session.key.generation };
    session.pending_client_command = .{ .target = target.key, .request_id = command.request_id, .action = command.action, .target_id = command.target_id };
    errdefer session.pending_client_command = null;
    try target.delivery.responses.push(.{ .client_command = routed });
    try self.effects.pump(self.effects.context, target);
}

/// Relays only the chosen UI's exact pending completion. Example: `try handler.complete(session, reply);`
pub fn complete(self: *Handler, session: *Session, completion: core.ClientCommand) !void {
    if (session.role != .ui) {
        return error.InvalidClientRole;
    }

    const requester = self.clients.resolve(.{ .id = completion.route.id, .generation = completion.route.generation }) orelse return;
    const pending = requester.pending_client_command orelse return;
    if (requester.closing or requester.role != .control or !pending.accepts(session.key, completion)) {
        return;
    }

    var reply = completion;
    reply.route = .{ .id = session.key.id, .generation = session.key.generation };
    try requester.delivery.responses.push(.{ .client_command_result = reply });
    requester.pending_client_command = null;
    try self.effects.pump(self.effects.context, requester);
}

const std = @import("std");
test "client command admission rejects stale generations and owns delivered text" {
    const Capture = struct {
        calls: usize = 0,
        fn pump(raw: *anyopaque, _: *Session) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
        }
    };
    var capture: Capture = .{};
    var requester: Session = undefined;
    requester.key = .{ .id = 1, .generation = 2 };
    requester.role = .control;
    requester.pending_client_command = null;
    var target: Session = undefined;
    target.key = .{ .id = 7, .generation = 9 };
    target.role = .ui;
    target.closing = false;
    target.delivery.client_identity = @enumFromInt(11);
    target.delivery.responses = .{};
    var clients: Store = .{};
    clients.items[0] = &target;
    var handler: Handler = .{ .clients = &clients, .effects = .{ .context = &capture, .pump = Capture.pump } };
    var command: core.ClientCommand = .{ .request_id = @enumFromInt(5), .route = .{ .id = 7, .generation = 8 }, .action = .workspace_select, .target_id = 42 };
    try std.testing.expectError(error.ClientNotFound, handler.request(&requester, command));
    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    command.route.generation = 9;
    try command.setText("owned");
    try handler.request(&requester, command);
    try command.setText("overwritten");
    const queued = target.delivery.responses.items[0].client_command;
    try std.testing.expectEqualStrings("owned", queued.text());
    try std.testing.expectEqual(@as(u64, 1), queued.route.id);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectError(error.InvalidClientCommand, handler.request(&requester, command));
}
