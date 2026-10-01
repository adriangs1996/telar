const std = @import("std");
const core = @import("telar-core");
const limit_reached = @import("limit_reached.zig");
const gitstatus = @import("gitstatus");
const max_output_bytes = 8 * 1024 * 1024;
const timeout_seconds = 600;
const output_limit = core.Limit.declare("repository.max_git_output_bytes", "bytes", max_output_bytes);

/// Runs Git with hooks, filters and lazy provider access disabled. Example: `const line = try repository_git.read(init, root, &.{ "rev-parse", "HEAD" });`.
pub fn read(init: std.process.Init, root: []const u8, arguments: []const []const u8) ![]const u8 {
    const result = try gitstatus.untrusted_git.run(init.io, .{
        .environ = init.minimal.environ,
        .path = root,
        .arguments = arguments,
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(timeout_seconds) } },
        .stdout = .{ .keep_head = max_output_bytes },
    });
    defer result.deinit();
    if (result.dropped != 0) {
        limit_reached.report(.{ .limit = output_limit, .requested = result.stdout.len + result.dropped });
        return error.RepositoryGitOutputLimit;
    }

    return init.arena.allocator().dupe(u8, result.line());
}

/// Refuses object formats whose external content cannot be prepared by a bundle. Example: `try repository_git.ready(init, root, commit);`.
pub fn ready(init: std.process.Init, root: []const u8, commit: []const u8) !void {
    if (!std.mem.eql(u8, try read(init, root, &.{ "rev-parse", "--is-shallow-repository" }), "false")) {
        return error.ShallowRepositoryUnsupported;
    }

    const configuration = try read(init, root, &.{ "config", "--local", "--name-only", "--list" });
    defer init.arena.allocator().free(configuration);
    if (std.mem.indexOf(u8, configuration, "extensions.partialclone") != null or std.mem.indexOf(u8, configuration, ".promisor") != null) {
        return error.PartialRepositoryUnsupported;
    }

    const tree = try read(init, root, &.{ "ls-tree", "-rz", commit });
    defer init.arena.allocator().free(tree);
    var lines = std.mem.splitScalar(u8, tree, 0);
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "160000 ")) {
            return error.SubmoduleRepositoryUnsupported;
        }

        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const name = line[tab + 1 ..];
        if (std.mem.eql(u8, name, ".gitattributes") or std.mem.endsWith(u8, name, "/.gitattributes")) {
            var fields = std.mem.tokenizeScalar(u8, line[0..tab], ' ');
            _ = fields.next();
            _ = fields.next();
            const blob = fields.next() orelse return error.InvalidGitTree;
            const attributes = try read(init, root, &.{ "cat-file", "blob", blob });
            defer init.arena.allocator().free(attributes);
            if (std.mem.indexOf(u8, attributes, "filter=lfs") != null or std.mem.indexOf(u8, attributes, "filter = lfs") != null) {
                return error.LfsRepositoryUnsupported;
            }
        }
    }

    const connectivity = try read(init, root, &.{ "fsck", "--connectivity-only", "--no-reflogs", commit });
    init.arena.allocator().free(connectivity);
}
