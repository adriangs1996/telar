//! Application policy for one configured bar-source result.

const data = @import("model");
const Failure = @import("Failure.zig");

pub const Result = union(enum) {
    content: data.Content,
    failed: Failure,
};

pub const Outcome = union(enum) {
    updated: data.BarUpdateCommit,
    unchanged,
    stale,
    failed: anyerror,
};

fn contentWith(text: []const u8) data.Content {
    var content: data.Content = .{};
    content.append(.{ .text = text }) catch unreachable;

    return content;
}
