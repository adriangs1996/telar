//! One client's index of the paths under a root. The build worker appends
//! entries into storage reserved up front and publishes the count with
//! release ordering; a query worker reads the published prefix at the same
//! time, so storage never moves while either runs. The runtime loop owns
//! every other field.

const core = @import("telar-core");
const fuzzymatch = @import("fuzzymatch");
const std = @import("std");
const ClientKey = @import("../history/ClientKey.zig");
const IndexedPath = @import("IndexedPath.zig");
const OwnedQuery = @import("OwnedQuery.zig");
const PathIndex = @This();

pub const max_entries = 128 * 1024;
pub const max_bytes = 8 * 1024 * 1024;

/// Why a build produced nothing a query can use.
pub const Failure = enum {
    none,
    unreadable,
};

gpa: std.mem.Allocator,
client: ClientKey,
root: [core.max_cwd_bytes]u8 = undefined,
root_len: u16 = 0,
bytes: []u8,
entries: []IndexedPath,
/// Reused by the one query that may run at a time.
matrix: *fuzzymatch.Matrix,

/// Written by the build worker only.
bytes_used: usize = 0,
entry_count: u32 = 0,
truncated: bool = false,
failure: Failure = .none,
/// The entries a query may read.
published: std.atomic.Value(u32) = .init(0),
/// Stored after the last publication.
complete: std.atomic.Value(bool) = .init(false),
/// Asks a running build to stop at its next entry.
cancelled: std.atomic.Value(bool) = .init(false),

/// Loop state: a worker holds this index.
building: bool = false,
querying: bool = false,
/// The client left; the last worker to finish frees the index.
abandoned: bool = false,
/// The newest request; `pending` until a query answers it.
wanted: OwnedQuery = .{},
pending: bool = false,
/// The root and refresh the newest request asked for.
wanted_root: [core.max_cwd_bytes]u8 = undefined,
wanted_root_len: u16 = 0,
rebuild: bool = false,
/// The last answer was taken before the build completed.
answered_partial: bool = false,

/// Reserves every buffer the build and query workers use.
///
/// ```zig
/// const index = try PathIndex.create(gpa, session.key);
/// defer index.destroy();
/// ```
pub fn create(gpa: std.mem.Allocator, client: ClientKey) !*PathIndex {
    const bytes = try gpa.alloc(u8, max_bytes);
    errdefer gpa.free(bytes);

    const entries = try gpa.alloc(IndexedPath, max_entries);
    errdefer gpa.free(entries);

    const matrix = try fuzzymatch.Matrix.create(gpa);
    errdefer gpa.destroy(matrix);

    const index = try gpa.create(PathIndex);
    index.* = .{
        .gpa = gpa,
        .client = client,
        .bytes = bytes,
        .entries = entries,
        .matrix = matrix,
    };
    return index;
}

pub fn destroy(self: *PathIndex) void {
    const gpa = self.gpa;
    gpa.free(self.bytes);
    gpa.free(self.entries);
    gpa.destroy(self.matrix);
    gpa.destroy(self);
}

pub fn rootSlice(self: *const PathIndex) []const u8 {
    return self.root[0..self.root_len];
}

pub fn wantedRootSlice(self: *const PathIndex) []const u8 {
    return self.wanted_root[0..self.wanted_root_len];
}

/// The path bytes of one published entry. Example: `const path = index.path(entry);`
pub fn path(self: *const PathIndex, entry: IndexedPath) []const u8 {
    return self.bytes[entry.offset..][0..entry.len];
}

/// Records the root the next request names; a different root or a refresh
/// asks for a rebuild. Example: `index.want(request.root, request.refresh);`
pub fn want(self: *PathIndex, root: []const u8, refresh: bool) void {
    std.debug.assert(root.len <= self.wanted_root.len);
    if (refresh or !std.mem.eql(
        u8,
        root,
        self.wantedRootSlice(),
    )) {
        self.rebuild = true;
    }

    @memcpy(self.wanted_root[0..root.len], root);
    self.wanted_root_len = @intCast(root.len);
}

/// Empties the index for a build of the wanted root. Only the loop calls
/// it, and only while no worker holds the index.
///
/// ```zig
/// index.reset();
/// try model.select.concurrent(.path_index_built, path_index_build.run, .{ index, model.io });
/// ```
pub fn reset(self: *PathIndex) void {
    std.debug.assert(!self.building and !self.querying);
    const root = self.wantedRootSlice();
    @memcpy(self.root[0..root.len], root);
    self.root_len = @intCast(root.len);
    self.bytes_used = 0;
    self.entry_count = 0;
    self.truncated = false;
    self.failure = .none;
    self.published.store(0, .release);
    self.complete.store(false, .release);
    self.cancelled.store(false, .release);
    self.rebuild = false;
    self.answered_partial = false;
}

/// Appends one entry for the build worker. Returns false once a bound is
/// reached, which marks the index truncated.
///
/// ```zig
/// if (!index.append("src/main.zig", .file)) return;
/// ```
pub fn append(self: *PathIndex, relative: []const u8, kind: core.PathKind) bool {
    if (self.entry_count == self.entries.len or self.bytes_used + relative.len > self.bytes.len) {
        self.truncated = true;
        return false;
    }

    @memcpy(self.bytes[self.bytes_used..][0..relative.len], relative);
    self.entries[self.entry_count] = .{
        .offset = @intCast(self.bytes_used),
        .len = @intCast(relative.len),
        .kind = kind,
    };
    self.bytes_used += relative.len;
    self.entry_count += 1;
    return true;
}

/// Makes every appended entry visible to queries.
pub fn publish(self: *PathIndex) void {
    self.published.store(self.entry_count, .release);
}

test "entries append within bounds and publish on demand" {
    const index = try PathIndex.create(
        std.testing.allocator,
        .{
            .id = 1,
            .generation = 1,
        },
    );
    defer index.destroy();

    index.want("/work", false);
    index.reset();
    try std.testing.expect(index.append("src/", .directory));
    try std.testing.expect(index.append("src/main.zig", .file));
    try std.testing.expectEqual(@as(u32, 0), index.published.load(.acquire));

    index.publish();
    try std.testing.expectEqual(@as(u32, 2), index.published.load(.acquire));
    try std.testing.expectEqualStrings("src/main.zig", index.path(index.entries[1]));
    try std.testing.expectEqualStrings("/work", index.rootSlice());

    index.want("/work", false);
    try std.testing.expect(!index.rebuild);
    index.want("/other", false);
    try std.testing.expect(index.rebuild);
}
