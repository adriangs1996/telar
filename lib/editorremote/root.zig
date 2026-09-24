//! Opening a file in an editor already running in a terminal: which editor
//! an executable is, how to reach its server (Neovim sockets, Vim's server
//! list, emacsclient), and expressions that re-check the process identity
//! before opening the path as literal data.

pub const Candidate = @import("Candidate.zig");
pub const Search = @import("Search.zig");
pub const editor = @import("editor.zig");
pub const expressions = @import("expressions.zig");

test {
    _ = @import("Candidate.zig");
    _ = @import("Search.zig");
    _ = @import("Target.zig");
    _ = @import("editor.zig");
    _ = @import("expressions.zig");
    _ = @import("remote.zig");
    _ = @import("remote_tests.zig");
}
