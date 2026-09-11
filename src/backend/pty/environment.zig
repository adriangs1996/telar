//! Owned environment passed to every process launched inside a Telar pane.

const std = @import("std");

pub const ChildEnvironment = @import("ChildEnvironment.zig");

test "terminal child environment provides Telar's Ghostty compatibility profile" {
    var inherited_map = std.process.Environ.Map.init(std.testing.allocator);
    defer inherited_map.deinit();

    try inherited_map.put("HOME", "/tmp/telar-home");
    try inherited_map.put("PATH", "/bin:/usr/bin");
    try inherited_map.put("TERM", "xterm-ghostty");
    try inherited_map.put("COLORTERM", "false");
    try inherited_map.put("TERM_PROGRAM", "outer-terminal");
    try inherited_map.put("TERM_PROGRAM_VERSION", "1.2.3");
    try inherited_map.put("TELAR_TERM_PROGRAM", "outer-telar");
    try inherited_map.put("TELAR_SOCKET", "/tmp/outer-telar.sock");
    try inherited_map.put("GHOSTTY_RESOURCES_DIR", "outer");
    const inherited_block = try inherited_map.createPosixBlock(std.testing.allocator, .{});
    defer inherited_block.deinit(std.testing.allocator);

    var environment = try ChildEnvironment.init(std.testing.allocator, .{ .block = inherited_block }, "telar");
    defer environment.deinit();

    const child: std.process.Environ = .{ .block = environment.block };

    try std.testing.expectEqualStrings("xterm-256color", std.process.Environ.getPosix(child, "TERM").?);
    try std.testing.expectEqualStrings("truecolor", std.process.Environ.getPosix(child, "COLORTERM").?);
    try std.testing.expectEqualStrings("ghostty", std.process.Environ.getPosix(child, "TERM_PROGRAM").?);
    try std.testing.expectEqualStrings("telar", std.process.Environ.getPosix(child, "TELAR_TERM_PROGRAM").?);
    try std.testing.expectEqualStrings("/tmp/telar-home", std.process.Environ.getPosix(child, "HOME").?);
    try std.testing.expect(std.process.Environ.getPosix(child, "TERM_PROGRAM_VERSION") == null);
    try std.testing.expect(std.process.Environ.getPosix(child, "TELAR_SOCKET") == null);
    try std.testing.expect(std.process.Environ.getPosix(child, "GHOSTTY_RESOURCES_DIR") == null);
}

test "terminal child environment applies bounded proxy overrides" {
    var inherited_map = std.process.Environ.Map.init(std.testing.allocator);
    defer inherited_map.deinit();

    try inherited_map.put("HTTPS_PROXY", "http://old.invalid");
    const inherited_block = try inherited_map.createPosixBlock(std.testing.allocator, .{});
    defer inherited_block.deinit(std.testing.allocator);

    var environment = try ChildEnvironment.initWithOverrides(std.testing.allocator, .{ .block = inherited_block }, .{
        .telar_term_program = "telar",
        .overrides = &.{
            .{ .name = "HTTPS_PROXY", .value = "http://127.0.0.1:45100" },
            .{ .name = "TELAR_PROXY_TLS", .value = "1" },
        },
    });
    defer environment.deinit();

    const child: std.process.Environ = .{ .block = environment.block };

    try std.testing.expectEqualStrings("http://127.0.0.1:45100", std.process.Environ.getPosix(child, "HTTPS_PROXY").?);
    try std.testing.expectEqualStrings("1", std.process.Environ.getPosix(child, "TELAR_PROXY_TLS").?);
}
