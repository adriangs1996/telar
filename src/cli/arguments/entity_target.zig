const std = @import("std");

pub const Target = union(enum) {
    current,
    id: u64,

    /// Accepts a nonzero identity or the caller's context. Example: `const target = try Target.parse("--current");`
    pub fn parse(text: []const u8) !Target {
        if (std.mem.eql(u8, text, "--current")) {
            return .current;
        }

        return .{ .id = try parseId(text) };
    }

    /// Resolves context without falling back to another object. Example: `const id = try target.resolve(environ, "TELAR_WORKSPACE_ID");`
    pub fn resolve(self: Target, environ: std.process.Environ, variable: [:0]const u8) !u64 {
        return switch (self) {
            .id => |id| id,
            .current => try parseId(environ.getPosix(variable) orelse return error.MissingCurrentIdentity),
        };
    }
};

fn parseId(text: []const u8) !u64 {
    const id = std.fmt.parseUnsigned(u64, text, 10) catch return error.InvalidIdentity;
    if (id == 0) {
        return error.InvalidIdentity;
    }

    return id;
}
