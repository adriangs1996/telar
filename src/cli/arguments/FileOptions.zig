const std = @import("std");
const FileOptions = @This();
pub const Action = enum { put, get };
action: Action,
path: []const u8,
bytes: ?u64 = null,

/// Transfers one explicit regular file. Example: `try FileOptions.parse(&.{ "put", "/work/brief.md", "--bytes", "12" });`.
pub fn parse(args: []const [*:0]const u8) !FileOptions {
    if (args.len != 2 and args.len != 4) {
        return error.InvalidFileArguments;
    }

    const path = std.mem.span(args[1]);
    if (!std.fs.path.isAbsolute(path)) {
        return error.AbsoluteFilePathRequired;
    }

    var options: FileOptions = .{ .action = std.meta.stringToEnum(Action, std.mem.span(args[0])) orelse return error.UnknownFileAction, .path = path };
    if (args.len == 4) {
        if (options.action != .put or !std.mem.eql(u8, std.mem.span(args[2]), "--bytes")) {
            return error.InvalidFileArguments;
        }

        options.bytes = try std.fmt.parseUnsigned(u64, std.mem.span(args[3]), 10);
    }

    if (options.action == .put and options.bytes == null) {
        return error.MissingTransferByteCount;
    }

    return options;
}
