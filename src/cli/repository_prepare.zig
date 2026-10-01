const builtin = @import("builtin");
const std = @import("std");
const core = @import("telar-core");
const gitstatus = @import("gitstatus");
const limit_reached = @import("limit_reached.zig");
const file_transfer = @import("file_transfer.zig");
const privatefile = @import("privatefile");
const PreparedRepository = @import("PreparedRepository.zig");
const RepositoryOptions = @import("arguments/RepositoryOptions.zig");
const worktree_git = @import("worktree_git.zig");
const repository_git = @import("repository_git.zig");
const repository_identity = @import("repository_identity.zig");
const repository_discovery = @import("repository_discovery.zig");
const machine_dispatch = @import("machine_dispatch.zig");
const max_bundle_bytes = 256 * 1024 * 1024;
const bundle_limit = core.Limit.declare("repository.max_bundle_bytes", "bytes", max_bundle_bytes);

/// Prepares a repository using source-side committed history only. Example: `return repository_prepare.run(init, options);`.
pub fn run(init: std.process.Init, options: RepositoryOptions) u8 {
    execute(init, options) catch |err| {
        std.debug.print("telar repository: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn execute(init: std.process.Init, options: RepositoryOptions) !void {
    if (options.action == .receive) {
        return receive(init, options);
    }

    const profile = switch (try machine_dispatch.resolve(init, std.mem.span(options.machine.?))) {
        .remote => |value| value,
        .local => return error.PreparationNeedsAnotherMachine,
    };
    const prepared = try prepare(init, options, profile);
    try print(init, prepared);
}

/// Shared by explicit preparation and worktree dispatch. Example: `const prepared = try repository_prepare.prepare(init, options, profile);`.
pub fn prepare(init: std.process.Init, options: RepositoryOptions, profile: core.MachineProfile) !PreparedRepository {
    const arena = init.arena.allocator();
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var directory = try std.Io.Dir.cwd().openDir(init.io, ".", .{});
    defer directory.close(init.io);
    const cwd = cwd_buffer[0..try directory.realPath(init.io, &cwd_buffer)];
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try worktree_git.mainRoot(init, cwd, &root_buffer);
    var commit_buffer: [worktree_git.max_commit_bytes]u8 = undefined;
    const commit = try worktree_git.commitOf(init, root, options.from, &commit_buffer);
    try repository_git.ready(init, root, commit);
    const origin = try repository_git.read(init, root, &.{ "config", "--get", "remote.origin.url" });
    var identity_buffer: [2048]u8 = undefined;
    const identity = try repository_identity.normalize(origin, &identity_buffer);
    const transport = try sanitized(arena, origin);
    const dirty = try worktree_git.changedFiles(init, root);
    if (dirty != 0) {
        std.debug.print("telar repository: {d} uncommitted files stay on this machine\n", .{dirty});
    }

    const temporary = try temporaryDirectory(init);
    defer std.Io.Dir.cwd().deleteTree(init.io, temporary) catch {};
    const bundle = try std.fmt.allocPrint(arena, "{s}/history.bundle", .{temporary});
    const ref = try std.fmt.allocPrint(arena, "refs/telar/transfer/{s}", .{std.fs.path.basename(temporary)});
    _ = try repository_git.read(init, root, &.{ "update-ref", ref, commit, "" });
    defer _ = repository_git.read(init, root, &.{ "update-ref", "-d", ref, commit }) catch "";
    var file = try std.Io.Dir.cwd().createFile(init.io, bundle, .{ .exclusive = true, .read = true, .permissions = .fromMode(0o600) });
    defer file.close(init.io);
    {
        const content = try gitstatus.untrusted_git.run(init.io, .{
            .environ = init.minimal.environ,
            .path = root,
            .arguments = &.{ "bundle", "create", "-", ref },
            .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(600) } },
            .stdout = .{ .keep_head = max_bundle_bytes },
        });
        defer content.deinit();
        if (content.dropped != 0) {
            limit_reached.report(.{ .limit = bundle_limit, .requested = content.stdout.len + content.dropped });
            return error.RepositoryBundleLimit;
        }

        try file.writePositionalAll(init.io, content.stdout, 0);
    }

    const size = (try file.stat(init.io)).size;
    if (size > max_bundle_bytes) {
        limit_reached.report(.{ .limit = bundle_limit, .requested = size });
        return error.RepositoryBundleLimit;
    }

    var words: std.ArrayList([*:0]const u8) = .empty;
    const program = core.remote_telar.program(profile.telarPath());
    for ([_][]const u8{ "telar", "exec", "--", program, "repository", "receive", "--identity", identity, "--transport", transport, "--commit", commit, "--ref", ref, "--bytes", try std.fmt.allocPrint(arena, "{d}", .{size}) }) |word| {
        try words.append(arena, (try arena.dupeZ(u8, word)).ptr);
    }

    if (options.workspace) |workspace| {
        try words.appendSlice(arena, &.{ "--workspace", workspace });
    }

    const output = try machine_dispatch.captureFile(init, &profile, words.items, file);
    defer init.gpa.free(output);
    const result = try std.json.parseFromSliceLeaky(struct { path: []const u8, commit: []const u8, repository: []const u8, reused: bool, repository_ready: bool }, arena, output, .{ .ignore_unknown_fields = true });
    if (!result.repository_ready or !std.fs.path.isAbsolute(result.path) or !std.mem.eql(u8, result.commit, commit) or !std.mem.eql(u8, result.repository, identity)) {
        return error.InvalidPreparationResult;
    }

    return .{
        .path = try arena.dupeZ(u8, result.path),
        .commit = try arena.dupe(u8, result.commit),
        .repository = try arena.dupe(u8, result.repository),
        .reused = result.reused,
    };
}

fn receive(init: std.process.Init, options: RepositoryOptions) !void {
    const arena = init.arena.allocator();
    var identity_buffer: [2048]u8 = undefined;
    if (!std.mem.eql(u8, try repository_identity.normalize(options.transport, &identity_buffer), options.identity) or !validCommit(options.commit) or !std.mem.startsWith(u8, options.ref, "refs/telar/transfer/") or options.bytes == 0 or options.bytes > max_bundle_bytes) {
        return error.InvalidRepositoryTransfer;
    }

    const managed = try repository_discovery.managedPath(init, options.identity);
    const parent = std.fs.path.dirname(managed).?;
    var parent_directory = try file_transfer.openDirectory(init.io, parent, true);
    defer parent_directory.close(init.io);
    const lock = try lockRepository(init.io, parent_directory, std.fs.path.basename(managed));
    defer lock.close(init.io);
    const existing = try repository_discovery.find(init, options.identity, options.workspace, null);
    const stage = try std.fmt.allocPrint(arena, "{s}.stage", .{managed});
    const marker = try std.fmt.allocPrint(arena, "{s}/owner", .{stage});
    if (std.Io.Dir.cwd().statFile(init.io, stage, .{ .follow_symlinks = false })) |stat| {
        if (stat.kind != .directory) {
            return error.UnownedRepositoryStage;
        }

        const prior = try privatefile.read(init.io, init.gpa, marker, .limited(2048)) orelse return error.UnownedRepositoryStage;
        defer init.gpa.free(prior);
        if (!std.mem.eql(u8, prior, options.identity)) {
            return error.UnownedRepositoryStage;
        }

        try std.Io.Dir.cwd().deleteTree(init.io, stage);
    } else |err| {
        if (err != error.FileNotFound) {
            return err;
        }
    }

    try std.Io.Dir.cwd().createDir(init.io, stage, .fromMode(0o700));
    defer std.Io.Dir.cwd().deleteTree(init.io, stage) catch {};
    try privatefile.replace(init.io, marker, options.identity);
    const temporary = stage;
    const bundle = try std.fmt.allocPrint(arena, "{s}/history.bundle", .{temporary});
    var file = try std.Io.Dir.cwd().createFile(init.io, bundle, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    defer file.close(init.io);
    var reader = std.Io.File.stdin().readerStreaming(init.io, &.{});
    var bytes: [64 * 1024]u8 = undefined;
    var received: u64 = 0;
    while (true) {
        const count = try reader.interface.readSliceShort(&bytes);
        if (count == 0) {
            break;
        }

        received += count;
        if (received > options.bytes) {
            return error.RepositoryTransferLength;
        }

        try file.writeStreamingAll(init.io, bytes[0..count]);
    }

    if (received != options.bytes) {
        return error.RepositoryTransferInterrupted;
    }

    const staged_repository = try std.fmt.allocPrint(arena, "{s}/repository", .{stage});
    const root = existing orelse staged_repository;
    if (existing == null) {
        try std.Io.Dir.cwd().createDir(init.io, staged_repository, .fromMode(0o700));
        _ = try repository_git.read(init, staged_repository, &.{ "init", "--template=" });
    }

    _ = try repository_git.read(init, root, &.{ "bundle", "verify", bundle });
    _ = try repository_git.read(init, root, &.{ "-c", "protocol.file.allow=always", "fetch", "--no-tags", "--", bundle, options.ref });
    const fetched = try repository_git.read(init, root, &.{ "rev-parse", "--verify", "FETCH_HEAD^{commit}" });
    if (!std.mem.eql(u8, fetched, options.commit)) {
        return error.RepositoryCommitMismatch;
    }

    try repository_git.ready(init, root, options.commit);
    if (existing == null) {
        _ = try repository_git.read(init, root, &.{ "config", "remote.origin.url", options.transport });
        _ = try repository_git.read(init, root, &.{ "checkout", "--detach", options.commit });
        try publishDirectory(try arena.dupeZ(u8, staged_repository), try arena.dupeZ(u8, managed));
    }

    try print(init, .{ .path = existing orelse managed, .commit = options.commit, .repository = options.identity, .repository_ready = true, .reused = existing != null, .environment = "not_run" });
}

fn validCommit(commit: []const u8) bool {
    if (commit.len != 40 and commit.len != 64) {
        return false;
    }

    for (commit) |byte| {
        if (!std.ascii.isHex(byte)) {
            return false;
        }
    }

    return true;
}

fn sanitized(arena: std.mem.Allocator, origin: []const u8) ![]const u8 {
    if (std.mem.indexOfAny(u8, origin, "?#\r\n\t ") != null) {
        return error.UnsupportedOrigin;
    }

    if (std.mem.indexOf(u8, origin, "://")) |separator| {
        const start = separator + 3;
        const slash = std.mem.indexOfScalarPos(u8, origin, start, '/') orelse return error.UnsupportedOrigin;
        const at = std.mem.lastIndexOfScalar(u8, origin[start..slash], '@');
        if (at) |index| {
            if (std.ascii.eqlIgnoreCase(origin[0..separator], "ssh") and std.mem.indexOfScalar(u8, origin[start .. start + index], ':') == null) {
                return arena.dupe(u8, origin);
            }

            return std.fmt.allocPrint(arena, "{s}{s}", .{ origin[0..start], origin[start + index + 1 ..] });
        }
    }

    return arena.dupe(u8, origin);
}

fn temporaryDirectory(init: std.process.Init) ![]const u8 {
    var nonce: [16]u8 = undefined;
    try init.io.randomSecure(&nonce);
    const base = init.minimal.environ.getPosix("TMPDIR") orelse "/tmp";
    const path = try std.fmt.allocPrint(init.arena.allocator(), "{s}/telar-transfer-{s}", .{ base, &std.fmt.bytesToHex(nonce, .lower) });
    try std.Io.Dir.cwd().createDir(init.io, path, .fromMode(0o700));
    return path;
}

fn print(init: std.process.Init, value: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try std.json.Stringify.value(value, .{}, &writer.interface);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}

const RenameFlag = enum(c_uint) { exclusive = 4 };
extern "c" fn renamex_np(old: [*:0]const u8, new: [*:0]const u8, flags: c_uint) c_int;

fn publishDirectory(stage: [:0]const u8, destination: [:0]const u8) !void {
    const result = if (builtin.os.tag == .macos)
        std.posix.errno(renamex_np(stage, destination, @intFromEnum(RenameFlag.exclusive)))
    else if (builtin.os.tag == .linux)
        std.os.linux.errno(std.os.linux.renameat2(std.posix.AT.FDCWD, stage, std.posix.AT.FDCWD, destination, .{ .NOREPLACE = true }))
    else
        return error.AtomicRepositoryPublicationUnsupported;
    switch (result) {
        .SUCCESS => {},
        .EXIST, .NOTEMPTY => return error.RepositoryDestinationOccupied,
        else => return error.RepositoryPublicationFailed,
    }
}

fn lockRepository(io: std.Io, parent: std.Io.Dir, name: []const u8) !std.Io.File {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const lock_name = try std.fmt.bufPrint(&buffer, "{s}.lock", .{name});
    const file = parent.createFile(io, lock_name, .{ .exclusive = true, .read = true, .permissions = .fromMode(0o600) }) catch |err| blk: {
        if (err != error.PathAlreadyExists) {
            return err;
        }

        break :blk file_transfer.openRegular(parent, lock_name) catch return error.UnsafeRepositoryLock;
    };
    errdefer file.close(io);
    const inode = try privatefile.Inode.fromDescriptor(file.handle);
    if (inode.kind() != .regular or inode.owner != std.c.getuid() or inode.links != 1 or inode.mode & 0o077 != 0) {
        return error.UnsafeRepositoryLock;
    }

    try file.lock(io, .exclusive);
    return file;
}
