//! Owned environment passed to every process launched inside a Telar pane.

const std = @import("std");

/// The immutable environment presented by Telar's terminal to every child.
/// It is built before pane launches enter the interactive path and borrowed
/// by `Command` while the child is spawned.
pub const Environment = struct {
    block: std.process.Environ.PosixBlock,
    gpa: std.mem.Allocator,

    pub const Override = struct {
        name: []const u8,
        value: []const u8,
    };

    pub const Configuration = struct {
        term_program: []const u8,
        overrides: []const Override,
    };

    pub fn init(gpa: std.mem.Allocator, inherited: std.process.Environ, term_program: []const u8) !Environment {
        return initWithOverrides(gpa, inherited, .{ .term_program = term_program, .overrides = &.{} });
    }

    /// Creates the immutable child environment after removing runtime-only
    /// authority and applying bounded pane-specific overrides.
    ///
    /// ```zig
    /// var environment = try Environment.initWithOverrides(gpa, inherited, .{ .term_program = "telar", .overrides = overrides });
    /// ```
    pub fn initWithOverrides(gpa: std.mem.Allocator, inherited: std.process.Environ, configuration: Configuration) !Environment {
        var map = try inherited.createMap(gpa);
        defer map.deinit();

        // terminal-browser otherwise treats this nested PTY as Ghostty and
        // writes Ghostty pane-discovery OSC 7 between Kitty image chunks.
        _ = map.swapRemove("GHOSTTY_RESOURCES_DIR");
        // Runtime authority is never ambient pane state.
        _ = map.swapRemove("TELAR_SOCKET");
        try map.put("TERM", "xterm-256color");
        try map.put("TERM_PROGRAM", configuration.term_program);
        for (configuration.overrides) |entry| try map.put(entry.name, entry.value);

        const block = try map.createPosixBlock(gpa, .{});
        return .{
            .block = block,
            .gpa = gpa,
        };
    }

    pub fn deinit(environment: *Environment) void {
        for (environment.block.slice) |entry| {
            const bytes = std.mem.span(@constCast(entry.?));
            std.crypto.secureZero(u8, bytes);
            environment.gpa.free(bytes);
        }
        environment.gpa.free(environment.block.slice);
        environment.* = undefined;
    }
};

test "terminal child environment removes inherited Ghostty identity" {
    var inherited_map = std.process.Environ.Map.init(std.testing.allocator);
    defer inherited_map.deinit();
    try inherited_map.put("HOME", "/tmp/telar-home");
    try inherited_map.put("PATH", "/bin:/usr/bin");
    try inherited_map.put("TERM", "xterm-ghostty");
    try inherited_map.put("TERM_PROGRAM", "ghostty");
    try inherited_map.put("TELAR_SOCKET", "/tmp/outer-telar.sock");
    try inherited_map.put("GHOSTTY_RESOURCES_DIR", "outer");
    const inherited_block = try inherited_map.createPosixBlock(std.testing.allocator, .{});
    defer inherited_block.deinit(std.testing.allocator);

    var environment = try Environment.init(std.testing.allocator, .{ .block = inherited_block }, "telar");
    defer environment.deinit();
    const child: std.process.Environ = .{ .block = environment.block };

    try std.testing.expectEqualStrings("xterm-256color", std.process.Environ.getPosix(child, "TERM").?);
    try std.testing.expectEqualStrings("telar", std.process.Environ.getPosix(child, "TERM_PROGRAM").?);
    try std.testing.expectEqualStrings("/tmp/telar-home", std.process.Environ.getPosix(child, "HOME").?);
    try std.testing.expect(std.process.Environ.getPosix(child, "TELAR_SOCKET") == null);
    try std.testing.expect(std.process.Environ.getPosix(child, "GHOSTTY_RESOURCES_DIR") == null);
}

test "terminal child environment applies bounded proxy overrides" {
    var inherited_map = std.process.Environ.Map.init(std.testing.allocator);
    defer inherited_map.deinit();
    try inherited_map.put("HTTPS_PROXY", "http://old.invalid");
    const inherited_block = try inherited_map.createPosixBlock(std.testing.allocator, .{});
    defer inherited_block.deinit(std.testing.allocator);
    var environment = try Environment.initWithOverrides(std.testing.allocator, .{ .block = inherited_block }, .{
        .term_program = "telar",
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
