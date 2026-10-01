const std = @import("std");
const ProjectOptions = @This();
cwd: []const u8,
detach: bool = false,

/// Explicit invocation authorizes the declared recipe. Example: `try ProjectOptions.parse(&.{ "setup", "--cwd", "/work" });`.
pub fn parse(args: []const [*:0]const u8) !ProjectOptions {
    if (args.len < 3 or !std.mem.eql(u8, std.mem.span(args[0]), "setup") or !std.mem.eql(u8, std.mem.span(args[1]), "--cwd")) {
        return error.InvalidProjectArguments;
    }

    var options: ProjectOptions = .{ .cwd = std.mem.span(args[2]) };
    if (!std.fs.path.isAbsolute(options.cwd)) {
        return error.AbsoluteProjectPathRequired;
    }

    for (args[3..]) |arg| {
        if (std.mem.eql(u8, std.mem.span(arg), "--detach")) {
            options.detach = true;
        } else if (!std.mem.eql(u8, std.mem.span(arg), "--json")) {
            return error.UnknownProjectOption;
        }
    }

    return options;
}
