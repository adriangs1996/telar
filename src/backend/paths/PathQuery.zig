//! One query over a path index and the reply it produces. The loop creates
//! it with owned copies, a worker ranks into it, and the client's delivery
//! frees it once the reply is encoded.

const core = @import("telar-core");
const fuzzymatch = @import("fuzzymatch");
const std = @import("std");
const ClientKey = @import("../history/ClientKey.zig");
const FoundPath = @import("FoundPath.zig");
const OwnedQuery = @import("OwnedQuery.zig");
const PathCandidate = @import("PathCandidate.zig");
const PathIndex = @import("PathIndex.zig");
const RankedPaths = @import("RankedPaths.zig");
const path_ranking = @import("path_ranking.zig");
const PathQuery = @This();

gpa: std.mem.Allocator,
index: *PathIndex,
client: ClientKey,
query: OwnedQuery,
root: [core.max_cwd_bytes]u8 = undefined,
root_len: u16 = 0,
scanned: u32 = 0,
complete: bool = false,
truncated: bool = false,
failure: PathIndex.Failure = .none,
matches: [core.max_path_results]FoundPath = undefined,
match_count: u8 = 0,

/// Captures the index's newest request. Example: `const query = try PathQuery.create(gpa, index);`
pub fn create(gpa: std.mem.Allocator, index: *PathIndex) !*PathQuery {
    const query = try gpa.create(PathQuery);
    query.* = .{
        .gpa = gpa,
        .index = index,
        .client = index.client,
        .query = index.wanted,
    };

    const root = index.rootSlice();
    @memcpy(query.root[0..root.len], root);
    query.root_len = @intCast(root.len);
    return query;
}

pub fn destroy(self: *PathQuery) void {
    self.gpa.destroy(self);
}

/// Ranks what the index has published so far. Runs on the observation path.
///
/// ```zig
/// try model.select.concurrent(.paths_found, PathQuery.run, .{ query, model.io });
/// ```
pub fn run(self: *PathQuery, io: std.Io) *PathQuery {
    _ = io;
    const index = self.index;
    self.complete = index.complete.load(.acquire);
    const published = index.published.load(.acquire);
    self.scanned = published;
    if (self.complete) {
        self.truncated = index.truncated;
        self.failure = index.failure;
    }

    var ranked: RankedPaths = .{};
    path_ranking.rank(
        index,
        &self.query,
        published,
        &ranked,
    );
    for (ranked.slice()) |candidate| {
        self.copy(candidate);
    }

    return self;
}

fn copy(self: *PathQuery, candidate: PathCandidate) void {
    const entry = self.index.entries[candidate.entry];
    const relative = self.index.path(entry);
    const match = &self.matches[self.match_count];
    match.* = .{
        .path_len = @intCast(relative.len),
        .kind = entry.kind,
    };
    @memcpy(match.path[0..relative.len], relative);

    const text = self.query.textSlice();
    if (text.len != 0 and fuzzymatch.match(
        self.index.matrix,
        relative,
        text,
        &match.positions,
    ) != null) {
        match.position_count = @intCast(text.len);
    }

    self.match_count += 1;
}

pub fn rootSlice(self: *const PathQuery) []const u8 {
    return self.root[0..self.root_len];
}

/// The wire reply, borrowing this query and `storage`.
///
/// ```zig
/// var storage: [core.max_path_results]core.PathMatch = undefined;
/// const payload = try core.encodePathResults(buffer, query.results(&storage));
/// ```
pub fn results(self: *const PathQuery, storage: *[core.max_path_results]core.PathMatch) core.PathResults {
    for (self.matches[0..self.match_count], 0..) |*match, position| {
        storage[position] = .{
            .path = match.path[0..match.path_len],
            .kind = match.kind,
            .positions = match.positions[0..match.position_count],
        };
    }

    return .{
        .request_id = self.query.request_id,
        .root = self.rootSlice(),
        .scanned = self.scanned,
        .complete = self.complete,
        .truncated = self.truncated,
        .matches = storage[0..self.match_count],
    };
}

test "a query copies ranked paths with the positions that ranked them" {
    const index = try PathIndex.create(
        std.testing.allocator,
        .{
            .id = 1,
            .generation = 1,
        },
    );
    defer index.destroy();

    index.want("/work", true);
    index.reset();
    _ = index.append("src/", .directory);
    _ = index.append("src/License.ts", .file);
    index.publish();
    index.complete.store(true, .release);
    index.wanted = .init(.{
        .request_id = @enumFromInt(4),
        .root = "/work",
        .query = "lic",
    });

    const query = try PathQuery.create(std.testing.allocator, index);
    defer query.destroy();

    _ = query.run(std.testing.io);
    var storage: [core.max_path_results]core.PathMatch = undefined;
    const reply = query.results(&storage);
    try std.testing.expect(reply.complete);
    try std.testing.expectEqual(@as(usize, 1), reply.matches.len);
    try std.testing.expectEqualStrings("src/License.ts", reply.matches[0].path);
    try std.testing.expectEqualSlices(
        u16,
        &.{ 4, 5, 6 },
        reply.matches[0].positions,
    );
}
