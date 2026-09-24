//! Syntax highlighting as roles: the languages a file path selects,
//! Tree-sitter capture names mapped to roles, and a bounded cache that
//! hands highlighting jobs out by source content and never lets a stale
//! completion recolor newer text. Parsing is the caller's.

pub const Entry = @import("Entry.zig");
pub const Job = @import("Job.zig");
pub const Result = @import("Result.zig");
pub const Role = @import("role.zig").Role;
pub const Store = @import("Store.zig");
pub const captures = @import("captures.zig");
pub const language = @import("language.zig");
pub const limits = @import("limits.zig");

test {
    _ = @import("Entry.zig");
    _ = @import("Job.zig");
    _ = @import("Result.zig");
    _ = @import("Store.zig");
    _ = @import("captures.zig");
    _ = @import("syntaxhl_tests.zig");
    _ = @import("language.zig");
    _ = @import("limits.zig");
    _ = @import("role.zig");
}
