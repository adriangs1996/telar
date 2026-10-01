const std = @import("std");
const RepositoryOptions = @This();
pub const Action = enum { prepare, receive };
action: Action,
machine: ?[*:0]const u8 = null,
from: []const u8 = "HEAD",
workspace: ?[*:0]const u8 = null,
identity: []const u8 = "",
transport: []const u8 = "",
commit: []const u8 = "",
ref: []const u8 = "",
bytes: u64 = 0,
json: bool = false,

/// Parses source preparation or the bounded destination receiver. Example: `try RepositoryOptions.parse(&.{ "prepare", "--machine", "box" });`.
pub fn parse(args: []const [*:0]const u8) !RepositoryOptions {
    if (args.len == 0) {
        return error.MissingRepositoryAction;
    }

    var options: RepositoryOptions = .{ .action = std.meta.stringToEnum(Action, std.mem.span(args[0])) orelse return error.UnknownRepositoryAction };
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = std.mem.span(args[index]);
        if (std.mem.eql(u8, arg, "--json")) {
            options.json = true;
            continue;
        }

        index += 1;
        if (index == args.len) {
            return error.MissingRepositoryOptionValue;
        }

        const value = std.mem.span(args[index]);
        if (std.mem.eql(u8, arg, "--machine") and options.action == .prepare) {
            options.machine = args[index];
        } else if (std.mem.eql(u8, arg, "--from") and options.action == .prepare) {
            options.from = value;
        } else if (std.mem.eql(u8, arg, "--workspace")) {
            options.workspace = args[index];
        } else if (std.mem.eql(u8, arg, "--identity") and options.action == .receive) {
            options.identity = value;
        } else if (std.mem.eql(u8, arg, "--transport") and options.action == .receive) {
            options.transport = value;
        } else if (std.mem.eql(u8, arg, "--commit") and options.action == .receive) {
            options.commit = value;
        } else if (std.mem.eql(u8, arg, "--ref") and options.action == .receive) {
            options.ref = value;
        } else if (std.mem.eql(u8, arg, "--bytes") and options.action == .receive) {
            options.bytes = try std.fmt.parseUnsigned(u64, value, 10);
        } else {
            return error.UnknownRepositoryOption;
        }
    }

    if (options.action == .prepare and options.machine == null) {
        return error.MissingMachineLabel;
    }

    return options;
}
