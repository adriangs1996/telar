//! Git computes the patch from frozen hook evidence; user files are never reread.
const std = @import("std");
const core = @import("telar-core");
const StorageInput = @import("StorageInput.zig");
const DiffInput = @import("DiffInput.zig");

/// Longest diff of two samples: each sampled byte appears once removed and
/// once added, a one-byte line gains a marker on each side, and Git's
/// headers name both temporary paths.
const max_diff_bytes = 4 * core.change_review.max_sample_bytes + 4 * std.fs.max_path_bytes;

/// Returns the whole patch of one before/after pair, owned by `storage.gpa`;
/// the edition keeps the part of it that fits `max_patch_bytes`.
///
/// ```zig
/// const patch = try sample_diff.create(storage, .{ .before = before, .after = after });
/// defer storage.gpa.free(patch);
/// ```
pub fn create(storage: StorageInput, input: DiffInput) ![]u8 {
    if (std.mem.indexOfAny(u8, input.after.path, "\r\n") != null) {
        return error.InvalidReviewPath;
    }
    var nonce: [8]u8 = undefined;
    storage.io.random(&nonce);
    var before_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var after_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const before_path = try std.fmt.bufPrint(&before_buffer, "{s}/sample-{x}-before", .{ storage.directory, nonce });
    const after_path = try std.fmt.bufPrint(&after_buffer, "{s}/sample-{x}-after", .{ storage.directory, nonce });
    const before_file = try std.Io.Dir.createFileAbsolute(storage.io, before_path, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    defer std.Io.Dir.deleteFileAbsolute(storage.io, before_path) catch {};
    {
        defer before_file.close(storage.io);
        try before_file.writeStreamingAll(storage.io, input.before.content);
    }
    const after_file = try std.Io.Dir.createFileAbsolute(storage.io, after_path, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    defer std.Io.Dir.deleteFileAbsolute(storage.io, after_path) catch {};
    {
        defer after_file.close(storage.io);
        try after_file.writeStreamingAll(storage.io, input.after.content);
    }
    const process = std.process.run(storage.gpa, storage.io, .{
        .argv = &.{ "git", "--no-pager", "diff", "--no-index", "--no-ext-diff", "--no-textconv", "--text", "--unified=3", "--color=never", "--", before_path, after_path },
        .stdout_limit = .limited(max_diff_bytes),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(2) } },
    }) catch |err| switch (err) {
        error.StreamTooLong => return error.ReviewPatchTooLarge,
        else => return err,
    };
    defer storage.gpa.free(process.stdout);
    defer storage.gpa.free(process.stderr);
    if (process.term != .exited or process.term.exited > 1) {
        return error.ReviewDiffFailed;
    }
    const start = std.mem.indexOf(u8, process.stdout, "@@ ") orelse return error.InvalidPatch;
    return std.fmt.allocPrint(storage.gpa, "{s} {s}\n{s}", .{ if (!input.before.exists) "Added" else if (!input.after.exists) "Deleted" else "Updated", input.after.path, process.stdout[start..] });
}
