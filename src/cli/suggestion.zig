const std = @import("std");
const core = @import("telar-core");
const Session = @import("Session.zig");
const SuggestionOptions = @import("arguments/SuggestionOptions.zig");
const control = @import("control.zig");

/// Prints an engine proposal without sending it to a terminal. Example: `std.process.exit(suggestion.run(init, options));`
pub fn run(init: std.process.Init, options: SuggestionOptions) u8 {
    return execute(init, options) catch |err| {
        std.debug.print("telar command suggest: {s}\n", .{control.describe(err)});
        return if (err == error.RuntimeTimeout) 3 else 1;
    };
}

fn execute(init: std.process.Init, options: SuggestionOptions) !u8 {
    const pane_id = try core.pane(try options.target.resolve(init.minimal.environ, "TELAR_PANE_ID"));
    var session = try Session.attach(init, options.socket);
    defer session.close();
    const response = try session.exchange(core.encodeSuggestCommand, core.SuggestCommand{ .request_id = .none, .pane_id = pane_id, .text = options.text });
    if (response != .command_suggestion) {
        return error.UnexpectedRuntimeResponse;
    }

    const value = response.command_suggestion;
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    if (options.json) {
        try std.json.Stringify.value(.{ .status = value.status, .command = value.text }, .{}, &output.interface);
        try output.interface.writeByte('\n');
    } else if (value.status == .ready) {
        try output.interface.print("{s}\n", .{value.text});
    } else {
        std.debug.print("telar command suggest: {s}\n", .{@tagName(value.status)});
    }

    try output.interface.flush();
    return switch (value.status) {
        .ready => 0,
        .timeout => 3,
        .unavailable, .failed => 1,
    };
}
