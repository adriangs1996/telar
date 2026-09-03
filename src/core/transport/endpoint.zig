//! Local endpoint paths shared by the runtime bootstrap and server.

const std = @import("std");

pub const Local = struct {
    storage: [std.Io.net.UnixAddress.max_len]u8 = undefined,
    path_len: usize,
    directory_len: usize = 0,

    pub fn explicit(endpoint_path: []const u8) !Local {
        if (!std.fs.path.isAbsolute(endpoint_path)) {
            return error.RelativePath;
        }
        if (endpoint_path.len > std.Io.net.UnixAddress.max_len) {
            return error.NameTooLong;
        }

        var endpoint = Local{ .path_len = endpoint_path.len };
        std.mem.copyForwards(u8, endpoint.storage[0..endpoint_path.len], endpoint_path);
        return endpoint;
    }

    /// Builds `<base>/<directory_name>/runtime.sock`. Only the final directory
    /// belongs to telar; the bootstrap must never chmod `base` itself.
    pub fn managed(base: []const u8, directory_name: []const u8) !Local {
        if (!std.fs.path.isAbsolute(base)) {
            return error.RelativePath;
        }
        if (directory_name.len == 0 or
            std.mem.indexOfAny(u8, directory_name, "/\\") != null)
        {
            return error.InvalidDirectoryName;
        }

        var endpoint = Local{ .path_len = 0 };
        const separator: []const u8 = if (std.mem.endsWith(u8, base, "/")) "" else "/";
        const directory = std.fmt.bufPrint(
            &endpoint.storage,
            "{s}{s}{s}",
            .{ base, separator, directory_name },
        ) catch return error.NameTooLong;
        endpoint.directory_len = directory.len;
        endpoint.path_len = (std.fmt.bufPrint(
            endpoint.storage[directory.len..],
            "/runtime.sock",
            .{},
        ) catch return error.NameTooLong).len + directory.len;
        return endpoint;
    }

    pub fn path(endpoint: *const Local) []const u8 {
        return endpoint.storage[0..endpoint.path_len];
    }

    pub fn managedDirectory(endpoint: *const Local) ?[]const u8 {
        if (endpoint.directory_len == 0) {
            return null;
        }
        return endpoint.storage[0..endpoint.directory_len];
    }
};

test "managed endpoints remain inside their own directory" {
    const endpoint = try Local.managed("/tmp/example", "telar-42");
    try std.testing.expectEqualStrings("/tmp/example/telar-42", endpoint.managedDirectory().?);
    try std.testing.expectEqualStrings("/tmp/example/telar-42/runtime.sock", endpoint.path());
}

test "explicit and managed endpoints must be absolute" {
    try std.testing.expectError(error.RelativePath, Local.explicit("runtime.sock"));
    try std.testing.expectError(error.RelativePath, Local.managed("tmp", "telar"));
    try std.testing.expectError(
        error.InvalidDirectoryName,
        Local.managed("/tmp", "other/telar"),
    );
}
