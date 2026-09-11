//! Provider request-body classification with bounded per-stream ownership.

const std = @import("std");
const core = @import("telar-core");
const claude = @import("claude_request.zig");
const request = @import("request_support.zig");

pub const ApiDialect = request.ApiDialect;
pub const RequestClass = request.RequestClass;
pub const max_concurrent_requests = 128;

pub const Observer = @import("Observer.zig");

pub const Fragment = @import("Fragment.zig");

pub const Streams = @import("Streams.zig");

const primary_body = "{\"messages\":[],\"tools\":[{\"name\":\"Read\"}],\"stream\":true}";
const auxiliary_body = "{\"messages\":[],\"tools\":[],\"stream\":true}";

test "request observer distinguishes primary and auxiliary Claude bodies" {
    var primary: Observer = .{};
    primary.init(.anthropic_messages);
    defer primary.deinit();
    primary.feed(primary_body);

    var auxiliary: Observer = .{};
    auxiliary.init(.anthropic_messages);
    defer auxiliary.deinit();
    auxiliary.feed(auxiliary_body);

    try std.testing.expectEqual(RequestClass.inference, primary.finish());
    try std.testing.expectEqual(RequestClass.auxiliary, auxiliary.finish());
}

test "request streams classify arbitrarily interleaved bodies independently" {
    var streams = Streams.init(.anthropic_messages);
    defer streams.deinit();
    try std.testing.expect(streams.start(1));
    try std.testing.expect(streams.start(3));
    const primary_split = primary_body.len / 2;
    const auxiliary_split = auxiliary_body.len / 2;

    streams.feed(.{ .stream_id = 1, .bytes = primary_body[0..primary_split] });
    streams.feed(.{ .stream_id = 3, .bytes = auxiliary_body[0..auxiliary_split] });
    streams.feed(.{ .stream_id = 1, .bytes = primary_body[primary_split..] });
    streams.feed(.{ .stream_id = 3, .bytes = auxiliary_body[auxiliary_split..] });

    try std.testing.expectEqual(RequestClass.auxiliary, streams.finish(3).?);
    try std.testing.expectEqual(RequestClass.inference, streams.finish(1).?);
}

test "finishing a request stream releases its slot for reuse" {
    var streams = Streams.init(.anthropic_messages);
    defer streams.deinit();
    try std.testing.expect(streams.start(7));
    streams.feed(.{ .stream_id = 7, .bytes = primary_body });
    try std.testing.expectEqual(RequestClass.inference, streams.finish(7).?);

    try std.testing.expect(streams.start(7));
    streams.feed(.{ .stream_id = 7, .bytes = auxiliary_body });
    try std.testing.expectEqual(RequestClass.auxiliary, streams.finish(7).?);
}

test "discarding a request stream erases partial input and releases its slot" {
    var streams = Streams.init(.anthropic_messages);
    defer streams.deinit();
    try std.testing.expect(streams.start(9));
    streams.feed(.{ .stream_id = 9, .bytes = primary_body[0 .. primary_body.len / 2] });

    streams.discard(9);

    try std.testing.expect(streams.finish(9) == null);
    try std.testing.expect(streams.start(9));
}

test "request stream capacity fails closed without disturbing active slots" {
    var streams = Streams.init(.anthropic_messages);
    defer streams.deinit();

    for (0..max_concurrent_requests) |index| {
        try std.testing.expect(streams.start(@intCast(index * 2 + 1)));
    }

    try std.testing.expect(!streams.start(@intCast(max_concurrent_requests * 2 + 1)));
    try std.testing.expect(!streams.start(1));
    streams.feed(.{ .stream_id = 1, .bytes = primary_body });
    try std.testing.expectEqual(RequestClass.inference, streams.finish(1).?);
}
