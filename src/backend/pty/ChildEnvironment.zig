/// The immutable environment presented by Telar's terminal to every child.
/// It is built before pane launches enter the interactive path and borrowed
/// by `Command` while the child is spawned.
const ChildEnvironment = @This();
const std = @import("std");
block: std.process.Environ.PosixBlock,
gpa: std.mem.Allocator,

pub const Override = struct {
    name: []const u8,
    value: []const u8,
};

pub const Configuration = struct {
    telar_term_program: []const u8,
    overrides: []const Override,
};

/// Creates a child environment with Telar's terminal compatibility
/// profile and explicit identity.
///
/// ```zig
/// var environment = try ChildEnvironment.init(gpa, inherited, "telar");
/// defer environment.deinit();
/// ```
pub fn init(gpa: std.mem.Allocator, inherited: std.process.Environ, telar_term_program: []const u8) !ChildEnvironment {
    return initWithOverrides(gpa, inherited, .{ .telar_term_program = telar_term_program, .overrides = &.{} });
}

/// Creates the immutable child environment after removing runtime-only
/// authority and applying bounded pane-specific overrides.
///
/// ```zig
/// var environment = try ChildEnvironment.initWithOverrides(gpa, inherited, .{ .telar_term_program = "telar", .overrides = overrides });
/// ```
pub fn initWithOverrides(gpa: std.mem.Allocator, inherited: std.process.Environ, configuration: Configuration) !ChildEnvironment {
    var map = try inherited.createMap(gpa);
    defer map.deinit();

    // terminal-browser otherwise treats this nested PTY as Ghostty and
    // writes Ghostty pane-discovery OSC 7 between Kitty image chunks.
    _ = map.swapRemove("GHOSTTY_RESOURCES_DIR");
    // Runtime authority is never ambient pane state.
    _ = map.swapRemove("TELAR_SOCKET");
    // Applications such as Claude Code only negotiate the extended Kitty
    // keyboard protocol with terminals they know implement it. Telar
    // implements Ghostty's contract while retaining its own identity in a
    // separate variable for integrations that need to detect Telar.
    _ = map.swapRemove("TERM_PROGRAM_VERSION");
    try map.put("TERM", "xterm-256color");
    try map.put("COLORTERM", "truecolor");
    try map.put("TERM_PROGRAM", "ghostty");
    try map.put("TELAR_TERM_PROGRAM", configuration.telar_term_program);
    for (configuration.overrides) |entry| {
        try map.put(entry.name, entry.value);
    }

    const block = try map.createPosixBlock(gpa, .{});
    return .{
        .block = block,
        .gpa = gpa,
    };
}

/// Scrubs every owned environment string before releasing its storage.
///
/// ```zig
/// environment.deinit();
/// ```
pub fn deinit(environment: *ChildEnvironment) void {
    for (environment.block.slice) |entry| {
        const bytes = std.mem.span(@constCast(entry.?));
        std.crypto.secureZero(u8, bytes);
        environment.gpa.free(bytes);
    }

    environment.gpa.free(environment.block.slice);
    environment.* = undefined;
}
