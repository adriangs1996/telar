//! config command grammar.

const std = @import("std");
const core = @import("telar-core");
const backend = @import("telar-backend");
const frontend = @import("telar-frontend");
const pty = backend.pty;
const Cursor = @import("cursor.zig").Cursor;

pub const ConfigCheckOptions = struct {
    path: ?[*:0]const u8 = null,
    profile: ?[*:0]const u8 = null,

    /// Example: `const options = try ConfigCheckOptions.parse(args);`.
    pub fn parse(args: []const [*:0]const u8) !ConfigCheckOptions {
        if (args.len < 1 or !std.mem.eql(u8, std.mem.span(args[0]), "check")) {
            return error.UnknownConfigAction;
        }

        var check: ConfigCheckOptions = .{};
        var check_index: usize = 1;
        while (check_index < args.len) {
            if (std.mem.eql(u8, std.mem.span(args[check_index]), "--profile")) {
                if (check.profile != null) {
                    return error.DuplicateProfileOption;
                }
                if (check_index + 1 >= args.len) {
                    return error.MissingProfileName;
                }

                check.profile = args[check_index + 1];
                check_index += 2;
            } else {
                if (check.path != null) {
                    return error.TooManyConfigArguments;
                }

                check.path = args[check_index];
                check_index += 1;
            }
        }
        return check;
    }
};
