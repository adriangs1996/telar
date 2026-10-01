const std = @import("std");
const limit_reached = @import("limit_reached.zig");
const core = @import("telar-core");
const sqlite = @import("sqlite");
const server = @import("server.zig");
const Session = @import("Session.zig");
const WorktreeCatalog = @import("WorktreeCatalog.zig");
const worktree_git = @import("worktree_git.zig");
const file_transfer = @import("file_transfer.zig");
const repository_git = @import("repository_git.zig");
const repository_identity = @import("repository_identity.zig");
const max_recorded_paths = 4096;
const paths_limit = core.Limit.declare("repository.max_recorded_paths", "recorded paths", max_recorded_paths);

/// Uses the existing runtime catalog and history paths, including closed workspaces.
/// Example: `const path = try repository_discovery.find(init, identity, null, null);`.
pub fn find(init: std.process.Init, identity: []const u8, selected: ?[*:0]const u8, socket: ?[*:0]const u8) !?[]const u8 {
    var session = try Session.open(init, socket);
    defer session.close();
    var catalog: WorktreeCatalog = .init(init.gpa);
    defer catalog.deinit();
    try session.fetchCatalog(&catalog);
    if (selected) |selection| {
        const text = std.mem.span(selection);
        const path = if (std.fmt.parseUnsigned(u64, text, 10)) |id|
            (catalog.findWorkspace(id) orelse return error.WorkspaceNotFound).path
        else |_|
            text;
        return try matching(init, path, identity) orelse return error.RepositoryNotInWorkspace;
    }

    var found: ?[]const u8 = null;
    for (catalog.workspaces.items) |workspace| {
        try consider(init, workspace.path, identity, &found);
    }

    for (catalog.worktrees.items) |worktree| {
        try consider(init, worktree.path, identity, &found);
    }

    var history_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const history = try server.resolveHistoryPath(init.minimal.environ, &history_buffer);
    var database: ?*sqlite.c.sqlite3 = null;
    if (sqlite.c.sqlite3_open_v2(history.path, &database, sqlite.c.SQLITE_OPEN_READONLY, null) == sqlite.c.SQLITE_OK) {
        defer _ = sqlite.c.sqlite3_close(database);
        _ = sqlite.c.sqlite3_busy_timeout(database, 5000);
        // A new runtime can accept control clients while its history worker
        // is still creating the schema. No session table means no old paths.
        const schema = try sqlite.prepare(database.?, "SELECT name FROM sqlite_master WHERE type='table' AND name='session'");
        const schema_result = sqlite.c.sqlite3_step(schema);
        _ = sqlite.c.sqlite3_finalize(schema);
        if (schema_result != sqlite.c.SQLITE_ROW and schema_result != sqlite.c.SQLITE_DONE) {
            return error.RepositoryHistoryUnavailable;
        }

        const statement = try sqlite.prepare(database.?, if (schema_result == sqlite.c.SQLITE_ROW) "SELECT DISTINCT workspace_path FROM session LIMIT 4097" else "SELECT '' WHERE 0");
        defer _ = sqlite.c.sqlite3_finalize(statement);
        var count: usize = 0;
        while (true) {
            const result = sqlite.c.sqlite3_step(statement);
            if (result == sqlite.c.SQLITE_DONE) {
                break;
            }

            if (result != sqlite.c.SQLITE_ROW) {
                return error.RepositoryHistoryUnavailable;
            }

            count += 1;
            if (count > max_recorded_paths) {
                limit_reached.report(.{ .limit = paths_limit, .requested = count });
                return error.RepositoryDiscoveryLimit;
            }

            try consider(init, sqlite.columnSlice(statement, 0), identity, &found);
        }
    } else {
        if (database) |db| {
            _ = sqlite.c.sqlite3_close(db);
        }

        if (std.Io.Dir.cwd().statFile(init.io, history.path, .{})) |_| {
            return error.RepositoryHistoryUnavailable;
        } else |err| {
            if (err != error.FileNotFound) {
                return err;
            }
        }
    }

    const managed = try managedPath(init, identity);
    try consider(init, managed, identity, &found);
    return found;
}

fn consider(init: std.process.Init, path: []const u8, identity: []const u8, found: *?[]const u8) !void {
    const candidate = try matching(init, path, identity) orelse return;
    if (found.*) |prior| {
        if (!std.mem.eql(u8, candidate, prior)) {
            return error.AmbiguousRepository;
        }
    } else {
        found.* = candidate;
    }
}

fn matching(init: std.process.Init, path: []const u8, identity: []const u8) !?[]const u8 {
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = worktree_git.mainRoot(init, path, &root_buffer) catch return null;
    var directory = try file_transfer.openDirectory(init.io, root, false);
    defer directory.close(init.io);
    const url = repository_git.read(init, root, &.{ "config", "--get", "remote.origin.url" }) catch return null;
    defer init.arena.allocator().free(url);
    var identity_buffer: [2048]u8 = undefined;
    const candidate = repository_identity.normalize(url, &identity_buffer) catch return null;
    if (!std.mem.eql(u8, candidate, identity)) {
        return null;
    }

    return try init.arena.allocator().dupe(u8, root);
}

/// Names a clone by the full hash of its non-secret matching identity.
/// Example: `const destination = try repository_discovery.managedPath(init, identity);`.
pub fn managedPath(init: std.process.Init, identity: []const u8) ![]const u8 {
    const home = init.minimal.environ.getPosix("HOME") orelse return error.HomeDirectoryUnavailable;
    const base = init.minimal.environ.getPosix("XDG_DATA_HOME") orelse try std.fmt.allocPrint(init.arena.allocator(), "{s}/.local/share", .{home});
    if (!std.fs.path.isAbsolute(base)) {
        return error.InvalidDataDirectory;
    }

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(identity, &digest, .{});
    return std.fmt.allocPrint(init.arena.allocator(), "{s}/telar/repositories/{s}", .{ base, &std.fmt.bytesToHex(digest, .lower) });
}
