//! Native editor protocols. No PTY keystrokes, screen heuristics or shell parsing.
const std = @import("std");
const Search = @import("Search.zig");
const editor = @import("editor.zig");
const expressions = @import("expressions.zig");
const privatefile = @import("privatefile");
const Inode = privatefile.Inode;
const c = @cImport({
    @cInclude("unistd.h");
});

/// Searches only bounded local endpoints and validates remote process identity.
/// Example: `try remote.open(search);`
pub fn open(search: *Search) !void {
    if (search.candidates.len == 0) {
        return;
    }

    switch (editor.identify(search.editor)) {
        .neovim => try neovim(search),
        .vim => try vim(search),
        .emacs => try emacs(search),
        .unsupported => {},
    }
}

fn neovim(search: *Search) !void {
    if (search.environment.getPosix("XDG_RUNTIME_DIR")) |root| {
        try scan(search, root, true);
    }

    if (search.opened != null) {
        return;
    }

    const user = search.environment.getPosix("USER") orelse return;
    // USER is a directory component, never an arbitrary traversal path.
    if (std.mem.findScalar(u8, user, '/') != null or user.len == 0) {
        return;
    }

    var storage: [std.fs.max_path_bytes]u8 = undefined;
    const temporary = search.environment.getPosix("TMPDIR") orelse "/tmp";
    const root = try std.fmt.bufPrint(&storage, "{s}/nvim.{s}", .{ temporary, user });
    try scan(search, root, true);
    if (search.opened == null and !std.mem.eql(u8, temporary, "/tmp")) {
        const fallback = try std.fmt.bufPrint(&storage, "/tmp/nvim.{s}", .{user});
        try scan(search, fallback, true);
    }
}

fn scan(search: *Search, root: []const u8, descend: bool) !void {
    if (search.opened != null or !ownedPath(root, .directory)) {
        return;
    }

    var directory = std.Io.Dir.cwd().openDir(search.io, root, .{ .iterate = true, .follow_symlinks = false }) catch return;
    defer directory.close(search.io);
    var entries = directory.iterate();
    while (search.entries_left > 0 and search.endpoints_left > 0) {
        const entry = try entries.next(search.io) orelse break;
        search.entries_left -= 1;
        var storage: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&storage, "{s}/{s}", .{ root, entry.name }) catch continue;
        if (entry.kind == .directory and descend) {
            try scan(search, path, false);
        } else if (entry.kind == .unix_domain_socket and ownedPath(path, .socket)) {
            search.endpoints_left -= 1;
            if (editor.identify(search.editor) == .emacs) {
                try emacsEndpoint(search, path);
            } else if (std.mem.startsWith(u8, entry.name, "nvim.")) {
                try vimEndpoint(search, path);
            }
        }

        if (search.opened != null) {
            return;
        }
    }
}

const PathKind = enum { directory, socket };

fn ownedPath(path: []const u8, kind: PathKind) bool {
    if (path.len == 0 or path[0] != '/' or path.len >= std.fs.max_path_bytes) {
        return false;
    }

    var storage: [std.fs.max_path_bytes]u8 = undefined;
    @memcpy(storage[0..path.len], path);
    storage[path.len] = 0;
    const inode = Inode.fromPath(storage[0..path.len :0], .no_follow) catch return false;
    if (inode.owner != c.getuid()) {
        return false;
    }

    const expected: Inode.Kind = switch (kind) {
        .directory => .directory,
        .socket => .socket,
    };
    return inode.kind() == expected and inode.mode & 0o022 == 0;
}

fn vim(search: *Search) !void {
    const output = search.command(&.{ search.editor, "--serverlist" }) catch return;
    defer Search.release(output);
    if (output.term != .exited or output.term.exited != 0) {
        return;
    }

    var names = std.mem.tokenizeAny(u8, output.stdout, "\r\n");
    while (names.next()) |name| {
        if (search.endpoints_left == 0 or search.opened != null) {
            return;
        }

        search.endpoints_left -= 1;
        try vimEndpoint(search, name);
    }
}

fn vimEndpoint(search: *Search, endpoint: []const u8) !void {
    const server_option = if (editor.identify(search.editor) == .neovim) "--server" else "--servername";
    const identity = search.command(&.{ search.editor, server_option, endpoint, "--remote-expr", "getpid() . \"\\n\" . hostname()" }) catch return;
    defer Search.release(identity);
    if (identity.term != .exited or identity.term.exited != 0) {
        return;
    }

    var lines = std.mem.tokenizeAny(u8, identity.stdout, "\r\n");
    const pid = std.fmt.parseInt(u32, lines.next() orelse return, 10) catch return;
    const remote_host = lines.next() orelse return;
    var hostname: [256:0]u8 = @splat(0);
    if (c.gethostname(&hostname, hostname.len) != 0) {
        return;
    }

    const local_host = std.mem.sliceTo(&hostname, 0);
    if (!std.mem.eql(u8, remote_host, local_host)) {
        return;
    }

    const index = search.find(pid) orelse search.find(parentProcess(search, pid) orelse return) orelse return;
    var storage: [expressions.max_bytes]u8 = undefined;
    const expression = try expressions.vim(
        &storage,
        .{
            .pid = pid,
            .path = search.path,
            .line = search.line,
            .column = search.column,
            .hostname = local_host,
        },
    );
    const output = try search.command(&.{ search.editor, server_option, endpoint, "--remote-expr", expression });
    defer Search.release(output);
    if (output.term != .exited or output.term.exited != 0 or !std.mem.eql(u8, std.mem.trim(u8, output.stdout, " \r\n"), "1")) {
        return error.EditorRejectedOpen;
    }

    search.opened = index;
}

/// Neovim 0.10 and later run the TUI and the server as two processes: the
/// pane's foreground process is the TUI, and the socket answers from its
/// child. The server's parent names the pane it draws in.
fn parentProcess(search: *Search, pid: u32) ?u32 {
    var pid_storage: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&pid_storage, "{d}", .{pid}) catch return null;
    const output = search.command(&.{ "/bin/ps", "-p", text, "-o", "ppid=" }) catch return null;
    defer Search.release(output);
    if (output.term != .exited or output.term.exited != 0) {
        return null;
    }

    return std.fmt.parseInt(u32, std.mem.trim(u8, output.stdout, " \r\n"), 10) catch null;
}

fn emacs(search: *Search) !void {
    for (search.candidates) |*candidate| {
        var pid_storage: [16]u8 = undefined;
        const pid = try std.fmt.bufPrint(&pid_storage, "{d}", .{candidate.process_group});
        const output = search.command(&.{ "/bin/ps", "-p", pid, "-o", "tty=" }) catch continue;
        defer Search.release(output);
        if (output.term != .exited or output.term.exited != 0) {
            continue;
        }

        const name = std.mem.trim(u8, output.stdout, " \r\n");
        if (name.len == 0 or std.mem.indexOfAny(u8, name, "?\r\n") != null) {
            continue;
        }

        const tty = std.fmt.bufPrint(&candidate.tty_bytes, "/dev/{s}", .{name}) catch continue;
        candidate.tty_len = @intCast(tty.len);
    }

    // Honor an explicit socket configured for emacsclient before discovery.
    if (search.environment.getPosix("EMACS_SOCKET_NAME")) |socket| {
        if (ownedPath(socket, .socket)) {
            try emacsEndpoint(search, socket);
        }
    }

    var storage: [std.fs.max_path_bytes]u8 = undefined;
    if (search.environment.getPosix("XDG_RUNTIME_DIR")) |root| {
        const directory = try std.fmt.bufPrint(&storage, "{s}/emacs", .{root});
        try scan(search, directory, false);
    }

    if (search.opened != null) {
        return;
    }

    const temporary = search.environment.getPosix("TMPDIR") orelse "/tmp";
    const directory = try std.fmt.bufPrint(&storage, "{s}/emacs{d}", .{ temporary, c.getuid() });
    try scan(search, directory, false);
    if (search.opened == null and !std.mem.eql(u8, temporary, "/tmp")) {
        const fallback = try std.fmt.bufPrint(&storage, "/tmp/emacs{d}", .{c.getuid()});
        try scan(search, fallback, false);
    }
}

fn emacsEndpoint(search: *Search, endpoint: []const u8) !void {
    var executable_storage: [std.fs.max_path_bytes]u8 = undefined;
    const executable = if (std.fs.path.dirname(search.editor)) |directory|
        try std.fmt.bufPrint(&executable_storage, "{s}/emacsclient", .{directory})
    else
        "emacsclient";
    const identity = search.command(&.{ executable, "--alternate-editor=/usr/bin/false", "--socket-name", endpoint, "--eval", "(emacs-pid)" }) catch return;
    defer Search.release(identity);
    if (identity.term != .exited or identity.term.exited != 0) {
        return;
    }

    const pid = std.fmt.parseInt(u32, std.mem.trim(u8, identity.stdout, " \r\n"), 10) catch return;
    var hostname: [256:0]u8 = @splat(0);
    if (c.gethostname(&hostname, hostname.len) != 0) {
        return;
    }

    for (search.candidates, 0..) |candidate, index| {
        if (candidate.tty_len == 0) {
            continue;
        }

        var storage: [expressions.max_bytes]u8 = undefined;
        const expression = try expressions.emacs(
            &storage,
            .{
                .pid = pid,
                .path = search.path,
                .line = search.line,
                .column = search.column,
                .tty = candidate.tty(),
                .hostname = std.mem.sliceTo(&hostname, 0),
            },
        );
        const output = try search.command(&.{ executable, "--alternate-editor=/usr/bin/false", "--socket-name", endpoint, "--eval", expression });
        defer Search.release(output);
        if (output.term != .exited or output.term.exited != 0) {
            return error.EditorRejectedOpen;
        }

        const result = std.mem.trim(u8, output.stdout, " \r\n");
        if (std.mem.eql(u8, result, "1")) {
            search.opened = index;
            return;
        } else if (!std.mem.eql(u8, result, "0")) {
            return error.EditorRejectedOpen;
        }
    }
}
