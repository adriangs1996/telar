const std = @import("std");
const core = @import("telar-core");
const Session = @import("Session.zig");
const Query = @This();
session: *Session,
command: core.ClientCommand,

/// Collects pages before emitting output; reloads cannot mix snapshots. Example: `try query.run(first, writer);`
pub fn run(self: *Query, first: core.ClientCommand, writer: *std.Io.Writer) !void {
    var arena = std.heap.ArenaAllocator.init(self.session.gpa);
    defer arena.deinit();
    const gpa = arena.allocator();
    var entries = std.array_list.Managed(std.json.Value).init(gpa);
    var reply = first;
    var generation: ?i64 = null;
    var pages: usize = 0;
    const limit: usize = if (self.command.action == .plugin_get) 65 else 32;
    while (true) {
        pages += 1;
        if (pages > limit or reply.status != .applied) {
            return error.InvalidPluginPage;
        }

        const page = try std.json.parseFromSliceLeaky(std.json.Value, gpa, reply.text(), .{ .allocate = .alloc_always });
        if (page != .object) {
            return error.InvalidPluginPage;
        }

        const version = page.object.get("generation") orelse return error.InvalidPluginPage;
        const items = page.object.get("entries") orelse return error.InvalidPluginPage;
        if (version != .integer or version.integer <= 0 or items != .array or items.array.items.len > 1) {
            return error.InvalidPluginPage;
        }

        if (generation) |expected| {
            if (version.integer != expected) {
                return error.StaleConfiguration;
            }
        } else {
            generation = version.integer;
        }

        try entries.appendSlice(items.array.items);
        if (reply.value == -1) {
            break;
        }

        if (reply.value <= self.command.value or reply.value >= limit) {
            return error.InvalidPluginPage;
        }

        self.command.value = reply.value;
        self.command.target_id = @intCast(generation.?);
        const received = try self.session.exchange(core.encodeRequestClientCommand, self.command);
        if (received != .client_command_result) {
            return error.UnexpectedRuntimeResponse;
        }

        reply = received.client_command_result;
        if (!std.meta.eql(reply.route, self.command.route) or reply.action != self.command.action or reply.target_id != self.command.target_id) {
            return error.UnexpectedRuntimeResponse;
        }

        if (reply.status == .failed) {
            std.debug.print("telar: {s}\n", .{reply.text()});
            return error.PluginQueryFailed;
        }
    }

    if (self.command.action == .plugin_get) {
        if (entries.items.len == 0 or entries.items[0] != .object) {
            return error.InvalidPluginPage;
        }

        var object = entries.items[0].object;
        var actions = std.array_list.Managed(std.json.Value).init(gpa);
        for (entries.items[1..]) |action| {
            if (action != .string) {
                return error.InvalidPluginPage;
            }

            try actions.append(action);
        }

        try object.put(gpa, "actions", .{ .array = actions });
        try std.json.Stringify.value(std.json.Value{ .object = object }, .{}, writer);
    } else {
        try std.json.Stringify.value(entries.items, .{}, writer);
    }
    try writer.writeByte('\n');
}
