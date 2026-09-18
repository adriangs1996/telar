const std = @import("std");

references: std.atomic.Value(usize) = .init(1),
gpa: std.mem.Allocator,
cwd: []const u8,
arguments: [][]const u8,
environment: std.process.Environ.Map,
timeout_ms: u32 = 15_000,

/// Releases an independent history reader configuration and erases credentials.
/// Example: `options.deinit();`.
pub fn deinit(options: *@This()) void {
    for (options.arguments) |argument| {
        options.gpa.free(argument);
    }

    for (options.environment.values()) |value| {
        std.crypto.secureZero(u8, @constCast(value));
    }

    options.environment.deinit();
    options.gpa.free(options.arguments);
    options.gpa.free(options.cwd);
}

/// Shares immutable configuration across independently joined actors.
/// Example: `const retained = options.retain();`.
pub fn retain(options: *@This()) *@This() {
    const previous = options.references.fetchAdd(1, .monotonic);
    std.debug.assert(previous != 0 and previous != std.math.maxInt(usize));
    return options;
}

/// Destroys a heap-owned configuration only after its final reader leaves.
/// Example: `options.release();`.
pub fn release(options: *@This()) void {
    const previous = options.references.fetchSub(1, .acq_rel);
    std.debug.assert(previous != 0);
    if (previous == 1) {
        const gpa = options.gpa;
        options.deinit();
        gpa.destroy(options);
    }
}

test "agent history options survive the session reference without cloning" {
    const gpa = std.testing.allocator;
    const options = try gpa.create(@This());
    options.* = .{
        .gpa = gpa,
        .cwd = try gpa.dupe(u8, "/tmp/source"),
        .arguments = try gpa.alloc([]const u8, 1),
        .environment = .init(gpa),
    };
    options.arguments[0] = try gpa.dupe(u8, "codex");
    try options.environment.put("CODEX_HOME", "/tmp/agent-profile");
    const retained = options.retain();
    options.release();
    defer retained.release();

    try std.testing.expect(retained == options);
    try std.testing.expectEqualStrings("/tmp/source", retained.cwd);
    try std.testing.expectEqualStrings("codex", retained.arguments[0]);
    try std.testing.expectEqualStrings("/tmp/agent-profile", retained.environment.get("CODEX_HOME").?);
}
