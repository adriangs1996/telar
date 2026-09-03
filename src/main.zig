const std = @import("std");
const cli_mod = @import("cli/root.zig");

const File = std.Io.File;

const version = "0.0.0";

// Library warnings cannot be written over a live frame. A later runtime can
// route them to its log; the bootstrap keeps stderr out of the drawing path.
pub const std_options: std.Options = .{ .log_level = .err };

/// Opt-in for development telemetry in optimized builds (`-Ddiagnostics`).
pub const telar_diagnostics = @import("build_options").diagnostics;

const Cli = cli_mod.Cli;

fn collectArgs(init: std.process.Init, storage: *[cli_mod.max_args][*:0]const u8) ![]const [*:0]const u8 {
    var iterator = init.minimal.args.iterate();
    var len: usize = 0;
    while (iterator.next()) |arg| {
        if (len == storage.len) {
            return error.TooManyArguments;
        }

        storage[len] = arg.ptr;
        len += 1;
    }
    return storage[0..len];
}

/// Selects and runs exactly one Telar command from the process arguments.
///
/// ```sh
/// telar server
/// ```
pub fn main(init: std.process.Init) !void {
    var arg_storage: [cli_mod.max_args][*:0]const u8 = undefined;
    const args = try collectArgs(init, &arg_storage);

    switch (try Cli.parse(args, init.minimal.environ)) {
        .help => try File.stdout().writeStreamingAll(init.io, cli_mod.usage),
        .version => try File.stdout().writeStreamingAll(init.io, "telar " ++ version ++ "\n"),
        .server => |options| try cli_mod.server.run(init, options),
        .history => |options| try cli_mod.history.run(init, options),
        .notification => |options| try cli_mod.notification.run(init, options),
        .config_check => |options| try cli_mod.config.runCheck(init, options),
        .plugin_worker => |options| try cli_mod.plugin.runWorker(init, options),
        .tap_worker => |options| try @import("telar-backend").plugins.runWorker(init, std.mem.span(options.entry)),
        .plugin => |options| try cli_mod.plugin.run(init, options),
        .agent => |options| std.process.exit(try cli_mod.agent.run(init, options)),
        .pane => |options| std.process.exit(try cli_mod.pane.run(init, options)),
        .workspace => |options| std.process.exit(try cli_mod.workspace.run(init, options)),
        .api => |options| try cli_mod.api.run(init, options),
        .hook => |options| try cli_mod.hook.run(init, options),
        .integration => |options| std.process.exit(try cli_mod.integration.run(init, options)),
        .proxy => |options| std.process.exit(try cli_mod.proxy.run(init, options)),
        .skill => try cli_mod.skill.run(init),
        .run => |options| {
            std.process.exit(try cli_mod.client.run(init, options));
        },
    }
}

test {
    _ = @import("cli/root.zig");
}
