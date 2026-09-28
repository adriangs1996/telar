//! Bounded SSH discovery data. All launch paths belong to the remote machine.

const core = @import("telar-core");
const Discovery = @import("Discovery.zig");
const std = @import("std");

test "remote discovery keeps remote launch defaults, spaces in paths and the schema" {
    const found = try Discovery.parse("/home/build user\n/bin/bash\n/run/user/501/telar/runtime.sock\n" ++ core.schema_id ++ "\n");
    try std.testing.expectEqualStrings("/home/build user", found.launchDefaults().cwd);
    try std.testing.expectEqualStrings("/bin/bash", found.launchDefaults().shell);
    try std.testing.expectEqualStrings("/run/user/501/telar/runtime.sock", found.endpoint());
    try std.testing.expect(found.compatible());

    const other = try Discovery.parse("/home/dev\n/bin/sh\n/run/telar.sock\n00000000\n");
    try std.testing.expect(!other.compatible());
}

test "remote discovery rejects malformed, injected, oversized and schema-less output" {
    for ([_][]const u8{
        "",
        "relative\n/bin/sh\n/run/telar.sock\n73cd7332",
        "/home/dev\n\n/run/telar.sock\n73cd7332",
        "/home/dev\n/bin/sh\n73cd7332",
        "/home/dev\n/bin/sh\n/run/telar.sock",
        "/home/dev\n/bin/sh\n/run/telar.sock\n73cd7332\nnoise",
        "/home/dev\n/bin/sh\n/run/telar:22.sock\n73cd7332",
        "/home/dev\n/bin/sh\n/run/\x00telar.sock\n73cd7332",
        "/home/dev\r\n/bin/sh\n/run/telar.sock\n73cd7332",
        "/home/dev\n/bin/sh\n/run/telar.sock\n73cd733",
        "/home/dev\n/bin/sh\n/run/telar.sock\n73cd73 2",
    }) |output| {
        try std.testing.expectError(error.RemoteDiscoveryUnreadable, Discovery.parse(output));
    }

    const oversized: [Discovery.max_output_bytes + 1]u8 = @splat('/');
    try std.testing.expectError(error.RemoteDiscoveryUnreadable, Discovery.parse(&oversized));
}
