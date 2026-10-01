const std = @import("std");
const core = @import("telar-core");
const ExecOptions = @This();

pub const Action = enum { start, status, output, cancel, forget, list };
action: Action = .start,
id: u64 = 0,
workspace: u64 = 0,
cwd: []const u8 = "",
arguments: []const [*:0]const u8 = &.{},
detach: bool = false,
json: bool = false,
stdin: bool = true,
timeout_seconds: u32 = 0,
socket: ?[*:0]const u8 = null,
stdout_offset: u64 = 0,
stderr_offset: u64 = 0,

/// Parses literal argv after `--`. Example: `try ExecOptions.parse(&.{ "--", "pwd" });`.
pub fn parse(args: []const [*:0]const u8) !ExecOptions {
    var options: ExecOptions = .{};
    var index: usize = 0;
    if (args.len != 0) {
        if (std.meta.stringToEnum(Action, std.mem.span(args[0]))) |action| {
            options.action = action;
            index += 1;
            if (action != .start and action != .list) {
                if (index == args.len) {
                    return error.MissingExecutionId;
                }

                options.id = try std.fmt.parseUnsigned(u64, std.mem.span(args[index]), 10);
                index += 1;
            }
        }
    }

    while (index < args.len) : (index += 1) {
        const arg = std.mem.span(args[index]);
        if (std.mem.eql(u8, arg, "--")) {
            options.arguments = args[index + 1 ..];
            break;
        } else if (std.mem.eql(u8, arg, "--detach")) {
            options.detach = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            options.json = true;
        } else if (std.mem.eql(u8, arg, "--no-stdin")) {
            options.stdin = false;
        } else {
            index += 1;
            if (index == args.len) {
                return error.MissingExecutionOptionValue;
            }

            const value = std.mem.span(args[index]);
            if (std.mem.eql(u8, arg, "--cwd")) {
                options.cwd = value;
            } else if (std.mem.eql(u8, arg, "--socket")) {
                options.socket = args[index];
            } else if (std.mem.eql(u8, arg, "--workspace")) {
                options.workspace = try std.fmt.parseUnsigned(u64, value, 10);
                if (options.workspace == 0) {
                    return error.InvalidWorkspaceId;
                }
            } else if (std.mem.eql(u8, arg, "--id")) {
                options.id = try std.fmt.parseUnsigned(u64, value, 10);
            } else if (std.mem.eql(u8, arg, "--timeout")) {
                options.timeout_seconds = try std.fmt.parseUnsigned(u32, value, 10);
            } else if (std.mem.eql(u8, arg, "--stdout-offset")) {
                options.stdout_offset = try std.fmt.parseUnsigned(u64, value, 10);
            } else if (std.mem.eql(u8, arg, "--stderr-offset")) {
                options.stderr_offset = try std.fmt.parseUnsigned(u64, value, 10);
            } else {
                return error.UnknownExecutionOption;
            }
        }
    }

    if (options.action == .start) {
        if (options.arguments.len == 0 or options.arguments.len > core.ExecutionRequest.max_arguments) {
            return error.InvalidExecutionArguments;
        }

        if (options.json and !options.detach) {
            return error.ForegroundExecutionUsesRawStreams;
        }
    } else if ((if (options.action == .list) options.id != 0 else options.id == 0) or options.arguments.len != 0 or options.detach or options.cwd.len != 0 or options.workspace != 0) {
        return error.InvalidExecutionOptions;
    }

    return options;
}
