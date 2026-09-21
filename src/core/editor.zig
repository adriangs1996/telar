//! Editor capabilities shared by discovery and link-opening policy.
const std = @import("std");

pub const Kind = enum { neovim, vim, emacs, unsupported };

/// Recognizes executable names without interpreting shell syntax. Example: `const kind = identify("/usr/bin/nvim");`
pub fn identify(executable: []const u8) Kind {
    const name = std.fs.path.basename(executable);
    if (std.mem.eql(u8, name, "nvim")) {
        return .neovim;
    }

    if (std.mem.eql(u8, name, "vim") or std.mem.eql(u8, name, "vi") or std.mem.startsWith(u8, name, "vim.")) {
        return .vim;
    }

    if (std.mem.eql(u8, name, "emacs") or std.mem.eql(u8, name, "Emacs") or std.mem.eql(u8, name, "emacsclient") or std.mem.startsWith(u8, name, "emacs-")) {
        return .emacs;
    }

    return .unsupported;
}

test "editor families recognize terminal package names without treating nano or shells as remote editors" {
    try std.testing.expectEqual(Kind.neovim, identify("/opt/bin/nvim"));
    try std.testing.expectEqual(Kind.vim, identify("/usr/bin/vim.basic"));
    try std.testing.expectEqual(Kind.emacs, identify("emacs-nox"));
    try std.testing.expectEqual(Kind.emacs, identify("Emacs"));
    try std.testing.expectEqual(Kind.emacs, identify("emacsclient"));
    try std.testing.expectEqual(Kind.unsupported, identify("nano"));
    try std.testing.expectEqual(Kind.unsupported, identify("sh"));
}
