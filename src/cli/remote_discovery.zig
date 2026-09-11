//! Bounded SSH discovery data. All launch paths belong to the remote machine.

const std = @import("std");

pub const LaunchDefaults = @import("LaunchDefaults.zig");

pub const Discovery = @import("Discovery.zig");

test "remote discovery keeps remote launch defaults and spaces in paths" {
    const found = try Discovery.parse("/home/build user\n/bin/bash\n/run/user/501/telar/runtime.sock\n");
    try std.testing.expectEqualStrings("/home/build user", found.launchDefaults().cwd);
    try std.testing.expectEqualStrings("/bin/bash", found.launchDefaults().shell);
    try std.testing.expectEqualStrings("/run/user/501/telar/runtime.sock", found.endpoint());
}

test "remote discovery rejects malformed, injected and oversized paths" {
    for ([_][]const u8{
        "",                                        "relative\n/bin/sh\n/run/telar.sock",         "/home/dev\n\n/run/telar.sock",
        "/home/dev\n/bin/sh",                      "/home/dev\n/bin/sh\n/run/telar.sock\nnoise", "/home/dev\n/bin/sh\n/run/telar:22.sock",
        "/home/dev\n/bin/sh\n/run/\x00telar.sock", "/home/dev\r\n/bin/sh\n/run/telar.sock",
    }) |output| {
        try std.testing.expectError(error.RemoteEndpointUnavailable, Discovery.parse(output));
    }

    const oversized: [std.fs.max_path_bytes + 1]u8 = @splat('/');
    try std.testing.expectError(error.RemoteEndpointUnavailable, Discovery.parse(&oversized));
}
