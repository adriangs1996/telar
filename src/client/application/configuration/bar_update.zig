//! Application policy for one configured bar-source result.

const ContentType = @import("../../bars/Content.zig");
const Failure = @import("Failure.zig");
const BarUpdateCommitType = @import("../../model/BarUpdateCommit.zig");

pub const Result = union(enum) {
    content: ContentType,
    failed: Failure,
};

pub const Outcome = union(enum) {
    updated: BarUpdateCommitType,
    unchanged,
    stale,
    failed: anyerror,
};

fn contentWith(text: []const u8) ContentType {
    var content: ContentType = .{};
    content.append(.{ .text = text }) catch unreachable;

    return content;
}
