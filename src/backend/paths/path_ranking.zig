//! Chooses the best published entries of an index for one query. A typed
//! query ranks by fuzzy score, then shorter path, then bytes; an empty
//! query browses: shallow first, directories before files, then bytes.

const core = @import("telar-core");
const fuzzymatch = @import("fuzzymatch");
const std = @import("std");
const OwnedQuery = @import("OwnedQuery.zig");
const PathIndex = @import("PathIndex.zig");
const RankedPaths = @import("RankedPaths.zig");
const PathCandidate = @import("PathCandidate.zig");

comptime {
    std.debug.assert(core.max_path_query_bytes <= fuzzymatch.max_needle_bytes);
}

const Order = struct {
    index: *const PathIndex,
    browse: bool,
};

/// Ranks the first `published` entries. Example: `rank(index, &query, published, &ranked);`
pub fn rank(index: *const PathIndex, query: *const OwnedQuery, published: u32, ranked: *RankedPaths) void {
    ranked.len = 0;
    const text = query.textSlice();
    const order: Order = .{
        .index = index,
        .browse = text.len == 0,
    };
    const limit = @min(query.limit, core.max_path_results);

    for (index.entries[0..published], 0..) |entry, position| {
        if (!admits(query.kind, entry.kind)) {
            continue;
        }

        const score = if (order.browse) 0 else fuzzymatch.score(index.path(entry), text) orelse continue;
        insert(
            ranked,
            order,
            .{
                .entry = @intCast(position),
                .score = score,
            },
            limit,
        );
    }
}

fn admits(filter: core.PathKindFilter, kind: core.PathKind) bool {
    return switch (filter) {
        .any => true,
        .files => kind == .file,
        .directories => kind == .directory,
    };
}

fn insert(ranked: *RankedPaths, order: Order, candidate: PathCandidate, limit: usize) void {
    var slot: usize = ranked.len;
    while (slot > 0 and better(
        order,
        candidate,
        ranked.items[slot - 1],
    )) {
        slot -= 1;
    }

    if (slot >= limit) {
        return;
    }

    const kept = @min(ranked.len, limit - 1);
    var move: usize = kept;
    while (move > slot) : (move -= 1) {
        ranked.items[move] = ranked.items[move - 1];
    }

    ranked.items[slot] = candidate;
    ranked.len = @intCast(kept + 1);
}

fn better(order: Order, left: PathCandidate, right: PathCandidate) bool {
    const left_entry = order.index.entries[left.entry];
    const right_entry = order.index.entries[right.entry];
    const left_path = order.index.path(left_entry);
    const right_path = order.index.path(right_entry);
    if (order.browse) {
        const left_depth = depth(left_path);
        const right_depth = depth(right_path);
        if (left_depth != right_depth) {
            return left_depth < right_depth;
        }

        if (left_entry.kind != right_entry.kind) {
            return left_entry.kind == .directory;
        }

        return std.mem.lessThan(
            u8,
            left_path,
            right_path,
        );
    }

    if (left.score != right.score) {
        return left.score > right.score;
    }

    if (left_path.len != right_path.len) {
        return left_path.len < right_path.len;
    }

    return std.mem.lessThan(
        u8,
        left_path,
        right_path,
    );
}

/// Separators before the last segment: `a/` and `a` are 0, `a/b/` is 1.
fn depth(relative: []const u8) usize {
    return std.mem.count(
        u8,
        std.mem.trimEnd(
            u8,
            relative,
            "/",
        ),
        "/",
    );
}

fn indexOf(paths: []const []const u8) !*PathIndex {
    const index = try PathIndex.create(
        std.testing.allocator,
        .{
            .id = 1,
            .generation = 1,
        },
    );
    index.want("/work", true);
    index.reset();
    for (paths) |relative| {
        const kind: core.PathKind = if (relative[relative.len - 1] == '/') .directory else .file;
        _ = index.append(relative, kind);
    }

    index.publish();
    return index;
}

fn rankedPath(index: *const PathIndex, ranked: *const RankedPaths, position: usize) []const u8 {
    return index.path(index.entries[ranked.items[position].entry]);
}

test "a typed query puts the file name match first" {
    const index = try indexOf(&.{
        "apps/",
        "apps/license-lookup-app/",
        "apps/license-lookup-app/src/",
        "apps/license-lookup-app/src/app.d.ts",
        "apps/license-lookup-app/src/types/",
        "apps/license-lookup-app/src/types/License.ts",
        "README.md",
    });
    defer index.destroy();

    const query: OwnedQuery = .init(.{
        .request_id = @enumFromInt(2),
        .root = "/work",
        .query = "licens.ts",
    });
    var ranked: RankedPaths = .{};
    rank(
        index,
        &query,
        index.published.load(.acquire),
        &ranked,
    );
    try std.testing.expectEqual(@as(u8, 2), ranked.len);
    try std.testing.expectEqualStrings("apps/license-lookup-app/src/types/License.ts", rankedPath(
        index,
        &ranked,
        0,
    ));
}

test "an empty query browses shallow directories first and honours the kind filter" {
    const index = try indexOf(&.{ "src/", "src/main.zig", "README.md", "docs/", "build.zig" });
    defer index.destroy();

    var ranked: RankedPaths = .{};
    const everything: OwnedQuery = .init(.{
        .request_id = @enumFromInt(2),
        .root = "/work",
    });
    rank(
        index,
        &everything,
        index.published.load(.acquire),
        &ranked,
    );
    try std.testing.expectEqualStrings("docs/", rankedPath(
        index,
        &ranked,
        0,
    ));
    try std.testing.expectEqualStrings("src/", rankedPath(
        index,
        &ranked,
        1,
    ));
    try std.testing.expectEqualStrings("README.md", rankedPath(
        index,
        &ranked,
        2,
    ));
    try std.testing.expectEqualStrings("src/main.zig", rankedPath(
        index,
        &ranked,
        4,
    ));

    const files: OwnedQuery = .init(.{
        .request_id = @enumFromInt(2),
        .root = "/work",
        .kind = .files,
        .limit = 2,
    });
    rank(
        index,
        &files,
        index.published.load(.acquire),
        &ranked,
    );
    try std.testing.expectEqual(@as(u8, 2), ranked.len);
    try std.testing.expectEqualStrings("README.md", rankedPath(
        index,
        &ranked,
        0,
    ));
    try std.testing.expectEqualStrings("build.zig", rankedPath(
        index,
        &ranked,
        1,
    ));
}
