//! Local endpoint paths shared by the runtime bootstrap and server.

const std = @import("std");

pub const Local = @import("Local.zig");

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
