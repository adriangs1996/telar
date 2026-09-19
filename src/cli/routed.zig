const std = @import("std");
const core = @import("telar-core");
const Session = @import("Session.zig");
const Options = @import("arguments/RoutedOptions.zig");
const control = @import("control.zig");

/// Discovers and targets one exact UI generation. Example: `std.process.exit(routed.run(init, options));`
pub fn run(init: std.process.Init, options: Options) u8 {
    return execute(init, options) catch |err| {
        std.debug.print("telar: {s}\n", .{control.describe(err)});
        return switch (err) {
            error.ClientNotFound => 2,
            error.RuntimeTimeout => 3,
            else => 1,
        };
    };
}

fn execute(init: std.process.Init, options: Options) !u8 {
    var session = try Session.attach(init, options.socket);
    defer session.close();
    const discovered = try session.exchange(core.encodeQueryClients, core.QueryClients{ .request_id = .none });
    if (discovered != .client_list) {
        return error.UnexpectedRuntimeResponse;
    }

    const route = for (discovered.client_list.entries[0..discovered.client_list.count]) |entry| {
        if (entry.id == options.client_id) {
            break entry;
        }
    } else return error.ClientNotFound;
    var command: core.ClientCommand = .{
        .request_id = .none,
        .route = .{ .id = route.id, .generation = route.generation },
        .action = options.action,
        .target_id = options.target_id,
        .value = options.value,
    };
    try command.setText(options.text);
    const received = try session.exchange(core.encodeRequestClientCommand, command);
    if (received != .client_command_result) {
        return error.UnexpectedRuntimeResponse;
    }

    const reply = received.client_command_result;
    if (reply.route.id != route.id or reply.route.generation != route.generation or reply.action != command.action or reply.target_id != command.target_id or reply.status == .request) {
        return error.UnexpectedRuntimeResponse;
    }

    if (reply.status == .failed) {
        std.debug.print("telar: {s}\n", .{reply.text()});
        return 1;
    }

    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    if (reply.action == .sidebar_get) {
        if (options.json) {
            try std.json.Stringify.value(.{ .visible = std.mem.eql(u8, reply.text(), "visible"), .width = reply.value }, .{}, &output.interface);
            try output.interface.writeByte('\n');
        } else {
            try output.interface.print("{s} {d} columns\n", .{ reply.text(), reply.value });
        }
    } else if (options.json) {
        try std.json.Stringify.value(.{ .client_id = route.id, .client_generation = route.generation, .action = @tagName(reply.action), .status = @tagName(reply.status), .target_id = reply.target_id, .value = reply.value, .text = reply.text() }, .{}, &output.interface);
        try output.interface.writeByte('\n');
    } else {
        try output.interface.print("{s}: {s}{s}{s}\n", .{ @tagName(reply.action), @tagName(reply.status), if (reply.length == 0) "" else " ", reply.text() });
    }

    try output.interface.flush();
    return 0;
}
