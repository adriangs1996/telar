const std = @import("std");
const ApiOptions = @This();

json: bool = false,

pub fn parse(args: []const [*:0]const u8) !ApiOptions {
    if (args.len == 0 or !std.mem.eql(u8, std.mem.span(args[0]), "schema")) {
        return error.UnknownApiAction;
    }

    var options: ApiOptions = .{};
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, std.mem.span(arg), "--json")) {
            options.json = true;
        } else {
            return error.UnknownApiOption;
        }
    }

    return options;
}
