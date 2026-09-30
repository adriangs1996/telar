//! Syntax highlighting as roles: the languages a file path selects,
//! Tree-sitter capture names mapped to roles, and the largest source a
//! caller may highlight. Parsing is the caller's.

pub const Role = @import("role.zig").Role;
pub const captures = @import("captures.zig");
pub const language = @import("language.zig");
pub const limits = @import("limits.zig");

test {
    _ = @import("captures.zig");
    _ = @import("syntaxhl_tests.zig");
    _ = @import("language.zig");
    _ = @import("limits.zig");
    _ = @import("role.zig");
}
