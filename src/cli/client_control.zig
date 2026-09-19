const std = @import("std");
const core = @import("telar-core");
const Session = @import("Session.zig");
const ClientOptions = @import("arguments/ClientOptions.zig");
const control = @import("control.zig");

/// Discovers generation-scoped interactive clients. Example: `std.process.exit(client_control.run(init, options));`
pub fn run(init: std.process.Init, options: ClientOptions) u8 {
    execute(init, options) catch |err| {
        std.debug.print("telar client: {s}\n", .{control.describe(err)});
        return switch (err) {
            error.RuntimeTimeout => 3,
            error.ClientNotFound => 2,
            else => 1,
        };
    };
    return 0;
}

fn execute(init: std.process.Init, options: ClientOptions) !void {
    var session = try Session.attach(init, options.socket);
    defer session.close();
    const response = try session.exchange(core.encodeQueryClients, core.QueryClients{ .request_id = .none });
    if (response != .client_list) {
        return error.UnexpectedRuntimeResponse;
    }

    const list = response.client_list;
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    if (options.action == .get) {
        for (list.entries[0..list.count]) |entry| {
            if (entry.id != options.target.?) {
                continue;
            }

            try writeOne(&output.interface, entry, options.json);
            try output.interface.flush();
            return;
        }

        return error.ClientNotFound;
    }

    if (options.json) {
        try std.json.Stringify.value(list.entries[0..list.count], .{}, &output.interface);
        try output.interface.writeByte('\n');
    } else {
        try output.interface.writeAll("CLIENT\tGENERATION\tIDENTITY\tATTACHMENTS\tLAST INPUT PANE\n");
        for (list.entries[0..list.count]) |entry| {
            try writeOne(&output.interface, entry, false);
        }
    }

    try output.interface.flush();
}

fn writeOne(writer: *std.Io.Writer, entry: core.ClientDescriptor, json: bool) !void {
    if (json) {
        try std.json.Stringify.value(entry, .{}, writer);
        try writer.writeByte('\n');
    } else {
        try writer.print("{d}\t{d}\t{d}\t{d}\t{d}\n", .{ entry.id, entry.generation, entry.identity, entry.attachments, entry.last_input_pane });
    }
}
