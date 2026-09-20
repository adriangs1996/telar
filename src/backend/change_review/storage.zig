//! Owner-only atomic review storage. Called solely by the observation worker.
const std = @import("std");
const core = @import("telar-core");
const Group = @import("Group.zig");
const Edition = @import("Edition.zig");
const Comment = @import("Comment.zig");
const c = @cImport({
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
});
const StorageInput = @import("StorageInput.zig");
const Persisted = @import("Persisted.zig");
const StoredEdition = @import("StoredEdition.zig");
const ArchiveRecord = @import("ArchiveRecord.zig");
const Context = @import("Context.zig");
pub const max_file_bytes = 8 * 1024 * 1024;
pub const max_global_bytes = StorageInput.max_global_bytes;
pub const max_storage_files = 131104;

pub fn ensure(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().createDir(io, path, .fromMode(0o700)) catch |err| {
        if (err != error.PathAlreadyExists) {
            return err;
        }
    };
    try private(path, true);
}

pub fn private(path: []const u8, directory: bool) !void {
    var buffer: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= buffer.len) {
        return error.InvalidReviewStorage;
    }
    @memcpy(buffer[0..path.len], path);
    buffer[path.len] = 0;
    var stat: c.struct_stat = undefined;
    if (c.lstat(buffer[0..path.len :0], &stat) != 0) {
        return error.InvalidReviewStorage;
    }
    const expected: u32 = if (directory) 0o040000 else 0o100000;
    if (stat.st_mode & 0o170000 != expected or stat.st_mode & 0o077 != 0 or stat.st_uid != c.geteuid() or (!directory and stat.st_nlink != 1)) {
        return error.InvalidReviewStorage;
    }
}

pub fn save(input: StorageInput, group: *const Group) !u32 {
    if (input.archive_id != 0 and (group.count != 1 or group.editions[0].?.id != input.archive_id)) {
        return error.InvalidReviewStorage;
    }

    var values: [Group.capacity]StoredEdition = undefined;
    for (group.editions[0..group.count], 0..) |item, index| {
        const edition = item.?;
        values[index] = .{ .identity = edition.identity, .next_comment = edition.next_comment, .snapshot = edition.view(.{ .request_id = @enumFromInt(1), .pane_id = group.context.pane.id, .pane_generation = group.context.pane.generation }) };
    }
    const records = if (input.archive_id == 0) group.records[0..group.total] else &.{};
    const bytes = try std.json.Stringify.valueAlloc(input.gpa, Persisted{ .version = 2, .records = records, .editions = values[0..group.count] }, .{});
    defer input.gpa.free(bytes);
    const archived_bytes = if (input.archive_id == 0) group.archivedBytes() else 0;
    if (bytes.len > max_file_bytes or bytes.len > input.byte_limit or archived_bytes > max_file_bytes - bytes.len) {
        return error.ReviewCapacity;
    }
    var target_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const target = try filename(input, group.key, &target_buffer);
    const previous_bytes = try ownedSize(input.io, target);
    var global_after: usize = 0;
    if (input.global_bytes) |global| {
        if (previous_bytes > global.*) {
            return error.InvalidReviewStorage;
        }

        const retained = global.* - previous_bytes;
        if (retained > input.global_limit or bytes.len > input.global_limit - retained) {
            return error.ReviewCapacity;
        }

        global_after = retained + bytes.len;
    }

    var random: [8]u8 = undefined;
    input.io.random(&random);
    var temporary_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const temporary = try std.fmt.bufPrint(&temporary_buffer, "{s}.{x}.tmp", .{ target, random });
    const file = try std.Io.Dir.createFileAbsolute(input.io, temporary, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    defer std.Io.Dir.deleteFileAbsolute(input.io, temporary) catch {};
    {
        defer file.close(input.io);
        try file.writeStreamingAll(input.io, bytes);
        try file.sync(input.io);
    }
    try std.Io.Dir.renameAbsolute(temporary, target, input.io);
    if (input.global_bytes) |global| {
        global.* = global_after;
    }

    return @intCast(bytes.len);
}

pub fn load(input: StorageInput, group: *Group) !void {
    if (group.count != 0 or group.total != 0) {
        return error.InvalidReviewStorage;
    }

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try filename(input, group.key, &path_buffer);
    var path_z_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_z_buffer, "{s}", .{path});
    const fd = std.c.open(path_z, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true });
    if (fd < 0) {
        if (std.posix.errno(fd) == .NOENT) {
            return;
        }
        return error.InvalidReviewStorage;
    }
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    defer file.close(input.io);
    const bytes = try input.gpa.alloc(u8, try privateSize(fd));
    defer input.gpa.free(bytes);
    var reader = file.readerStreaming(input.io, &.{});
    if (try reader.interface.readSliceShort(bytes) != bytes.len) {
        return error.InvalidReviewStorage;
    }
    const parsed = std.json.parseFromSlice(Persisted, input.gpa, bytes, .{ .allocate = .alloc_always }) catch |err| {
        return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidReviewStorage;
    };
    defer parsed.deinit();
    if (parsed.value.version != 2 or parsed.value.editions.len > Group.capacity or parsed.value.records.len > Group.archive_capacity) {
        return error.InvalidReviewStorage;
    }

    try validateManifest(input, parsed.value, bytes.len);
    for (parsed.value.editions) |stored| {
        const value = stored.snapshot;
        if (value.edition_id == 0 or value.revision == 0 or value.comment_count > core.change_review.max_comments) {
            return error.InvalidReviewStorage;
        }
        const edition = try input.gpa.create(Edition);
        errdefer input.gpa.destroy(edition);
        edition.* = .{ .id = value.edition_id, .revision = value.revision, .identity = stored.identity, .next_comment = stored.next_comment, .source = value.source, .reviewed = value.reviewed, .delivery = value.delivery, .feedback_id = value.feedback_id };
        try edition.setPatch(value.patch);
        if (value.feedback.len > core.change_review.max_feedback_bytes) {
            return error.InvalidReviewStorage;
        }
        if ((value.delivery == .pending and (value.feedback_id != value.edition_id or value.feedback.len == 0)) or !std.unicode.utf8ValidateSlice(value.feedback) or std.mem.indexOfScalar(u8, value.feedback, 0) != null) {
            return error.InvalidReviewStorage;
        }
        edition.feedback_len = @intCast(value.feedback.len);
        @memcpy(edition.feedback[0..value.feedback.len], value.feedback);
        for (value.comments(), 0..) |comment, index| {
            if (comment.id == 0 or comment.id >= stored.next_comment) {
                return error.InvalidReviewStorage;
            }
            for (value.comments()[0..index]) |previous| {
                if (previous.id == comment.id) {
                    return error.InvalidReviewStorage;
                }
            }
            try edition.validateAnchor(.{ .request_id = @enumFromInt(1), .pane_id = value.pane_id, .pane_generation = value.pane_generation, .action = .save_comment, .path = comment.path, .first_line = comment.first_line, .last_line = comment.last_line, .side = comment.side });
            edition.comment_storage[index] = try Comment.init(comment.id, .{ .request_id = @enumFromInt(1), .pane_id = value.pane_id, .pane_generation = value.pane_generation, .action = .save_comment, .path = comment.path, .first_line = comment.first_line, .last_line = comment.last_line, .side = comment.side, .body = comment.body, .draft = comment.draft });
        }
        edition.comment_count = value.comment_count;
        group.editions[group.count] = edition;
        group.count += 1;
    }

    group.total = @intCast(parsed.value.records.len);
    @memcpy(group.records[0..group.total], parsed.value.records);
}

/// Includes retained crash temporaries in the global budget before accepting writes.
/// Example: `const bytes = try storage.diskUsage(io, directory);`
pub fn diskUsage(io: std.Io, directory: []const u8) !usize {
    try private(directory, true);
    var handle = try std.Io.Dir.openDirAbsolute(io, directory, .{ .iterate = true, .follow_symlinks = false });
    defer handle.close(io);
    var iterator = handle.iterate();
    var files: usize = 0;
    var bytes: usize = 0;
    while (try iterator.next(io)) |entry| {
        if (files == max_storage_files) {
            return error.ReviewCapacity;
        }

        files += 1;
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ directory, entry.name });
        const size = try ownedSize(io, path);
        if (size > max_global_bytes - bytes) {
            return error.ReviewCapacity;
        }

        bytes += size;
    }

    return bytes;
}

/// Measures the current manifest before reserving space for a separate archive.
/// Example: `const bytes = try storage.manifestBytes(input, group.key);`
pub fn manifestBytes(input: StorageInput, key: [64]u8) !usize {
    var manifest = input;
    manifest.archive_id = 0;
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    return ownedSize(input.io, try filename(manifest, key, &path_buffer));
}

fn ownedSize(io: std.Io, path: []const u8) !usize {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_buffer, "{s}", .{path});
    const fd = std.c.open(path_z, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true });
    if (fd < 0) {
        if (std.posix.errno(fd) == .NOENT) {
            return 0;
        }

        return error.InvalidReviewStorage;
    }

    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    defer file.close(io);
    return privateSize(fd);
}

fn privateSize(fd: std.posix.fd_t) !usize {
    var stat: c.struct_stat = undefined;
    if (c.fstat(fd, &stat) != 0 or stat.st_mode & 0o170000 != 0o100000 or stat.st_mode & 0o077 != 0 or stat.st_uid != c.geteuid() or stat.st_nlink != 1 or stat.st_size < 0 or stat.st_size > max_file_bytes) {
        return error.InvalidReviewStorage;
    }

    return @intCast(stat.st_size);
}

fn filename(input: StorageInput, key: [64]u8, buffer: []u8) ![]const u8 {
    if (input.archive_id == 0) {
        return std.fmt.bufPrint(buffer, "{s}/{s}.json", .{ input.directory, key });
    }

    return std.fmt.bufPrint(buffer, "{s}/{s}-{d}.json", .{ input.directory, key, input.archive_id });
}

fn validateManifest(input: StorageInput, value: Persisted, manifest_bytes: usize) !void {
    if (input.archive_id != 0) {
        if (value.records.len != 0 or value.editions.len != 1 or value.editions[0].snapshot.edition_id != input.archive_id) {
            return error.InvalidReviewStorage;
        }

        return;
    }

    var total_bytes = manifest_bytes;
    for (value.records) |record| {
        if (record.bytes > max_file_bytes - total_bytes) {
            return error.InvalidReviewStorage;
        }

        total_bytes += record.bytes;
    }

    var present: [Group.archive_capacity]bool = @splat(false);
    for (value.editions) |stored| {
        const id = stored.snapshot.edition_id;
        if (id == 0 or id > value.records.len or present[id - 1] or !std.mem.eql(u8, &stored.identity, &value.records[id - 1].identity)) {
            return error.InvalidReviewStorage;
        }

        present[id - 1] = true;
    }

    for (value.records, 0..) |record, index| {
        if (record.bytes == 0 and !present[index]) {
            return error.InvalidReviewStorage;
        }
    }
}

test "review manifest rejects duplicate missing mismatched and oversized archive records" {
    const input: StorageInput = .{ .gpa = std.testing.allocator, .io = std.testing.io, .directory = "/unused" };
    const record: ArchiveRecord = .{ .identity = @splat(1) };
    const stored: StoredEdition = .{ .identity = record.identity, .next_comment = 1, .snapshot = .{ .request_id = @enumFromInt(1), .pane_id = try core.pane(1), .pane_generation = 1, .edition_id = 1 } };
    try validateManifest(input, .{ .version = 2, .records = &.{record}, .editions = &.{stored} }, 100);
    try std.testing.expectError(error.InvalidReviewStorage, validateManifest(input, .{ .version = 2, .records = &.{record}, .editions = &.{ stored, stored } }, 100));
    try std.testing.expectError(error.InvalidReviewStorage, validateManifest(input, .{ .version = 2, .records = &.{ record, record }, .editions = &.{stored} }, 100));
    var mismatched = stored;
    mismatched.identity[0] = 2;
    try std.testing.expectError(error.InvalidReviewStorage, validateManifest(input, .{ .version = 2, .records = &.{record}, .editions = &.{mismatched} }, 100));
    var archived = record;
    archived.bytes = 1;
    try std.testing.expectError(error.InvalidReviewStorage, validateManifest(input, .{ .version = 2, .records = &.{archived}, .editions = &.{} }, max_file_bytes));
    var archive_input = input;
    archive_input.archive_id = 2;
    try std.testing.expectError(error.InvalidReviewStorage, validateManifest(archive_input, .{ .version = 2, .records = &.{}, .editions = &.{stored} }, 100));
}

test "review archive roundtrip keeps bounded atomic private files separate from manifest" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try std.testing.expectEqual(@as(c_int, 0), c.fchmod(temp.dir.handle, 0o700));
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = directory_buffer[0..try temp.dir.realPath(io, &directory_buffer)];
    const input: StorageInput = .{ .gpa = gpa, .io = io, .directory = directory };
    const context = try Context.init(.{ .id = try core.pane(1), .generation = 1 }, .codex, "test-session");
    var group: Group = .{ .key = @splat('a'), .context = context };
    defer group.deinit(gpa);
    const edition = try gpa.create(Edition);
    edition.* = .{ .id = 1, .identity = @splat(1) };
    group.editions[0] = edition;
    group.count = 1;
    try edition.setPatch("--- a/source.zig\n+++ b/source.zig\n@@ -1 +1 @@\n-old\n+new\n");
    var archive_input = input;
    archive_input.archive_id = 1;
    const archive_bytes = try save(archive_input, &group);
    archive_input.byte_limit = 1;
    try std.testing.expectError(error.ReviewCapacity, save(archive_input, &group));
    archive_input.byte_limit = max_file_bytes;
    var archived: Group = .{ .key = group.key, .context = context };
    defer archived.deinit(gpa);
    try load(archive_input, &archived);
    try std.testing.expectEqual(@as(u16, 0), archived.total);
    try std.testing.expectEqual(@as(u8, 1), archived.count);
    try std.testing.expectEqualStrings(edition.text(), archived.editions[0].?.text());
    var manifest: Group = .{ .key = group.key, .context = context, .total = 1 };
    manifest.records[0] = .{ .identity = edition.identity, .bytes = archive_bytes };
    const manifest_bytes = try save(input, &manifest);
    var restored: Group = .{ .key = group.key, .context = context };
    defer restored.deinit(gpa);
    try load(input, &restored);
    try std.testing.expectEqual(@as(u16, 1), restored.total);
    try std.testing.expectEqual(@as(u8, 0), restored.count);
    try std.testing.expectEqual(archive_bytes, restored.records[0].bytes);
    try std.testing.expectEqual(manifest_bytes, try manifestBytes(archive_input, group.key));
    var global_bytes = try diskUsage(io, directory);
    try std.testing.expectEqual(@as(usize, archive_bytes) + manifest_bytes, global_bytes);
    var bounded = archive_input;
    bounded.global_bytes = &global_bytes;
    bounded.global_limit = global_bytes;
    _ = try save(bounded, &group);
    try edition.setPatch("--- a/source.zig\n+++ b/source.zig\n@@ -1 +1 @@\n-old\n+new and longer\n");
    try std.testing.expectError(error.ReviewCapacity, save(bounded, &group));
    try std.testing.expectEqual(global_bytes, try diskUsage(io, directory));
    const leftover = try temp.dir.createFile(io, "crash.tmp", .{ .permissions = .fromMode(0o600), .exclusive = true });
    try leftover.writeStreamingAll(io, "remaining");
    leftover.close(io);
    try std.testing.expectEqual(global_bytes + "remaining".len, try diskUsage(io, directory));
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    try private(try filename(input, group.key, &path_buffer), false);
    try private(try filename(archive_input, group.key, &path_buffer), false);
    const incompatible_text = "{\"version\":1,\"editions\":[]}";
    const incompatible_file = try temp.dir.createFile(io, "c" ** 64 ++ ".json", .{ .permissions = .fromMode(0o600), .exclusive = true });
    try incompatible_file.writeStreamingAll(io, incompatible_text);
    incompatible_file.close(io);
    var incompatible: Group = .{ .key = @splat('c'), .context = context };
    try std.testing.expectError(error.InvalidReviewStorage, load(input, &incompatible));
    try std.testing.expectEqual(incompatible_text.len, try manifestBytes(input, incompatible.key));

    try temp.dir.symLink(io, "a" ** 64 ++ "-1.json", "b" ** 64 ++ "-1.json", .{});
    var unsafe: Group = .{ .key = @splat('b'), .context = context };
    try std.testing.expectError(error.InvalidReviewStorage, load(archive_input, &unsafe));
    try std.testing.expectError(error.InvalidReviewStorage, diskUsage(io, directory));
}
