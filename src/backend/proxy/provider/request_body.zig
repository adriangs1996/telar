//! Provider request-body classification with bounded per-stream ownership.

const std = @import("std");
const core = @import("telar-core");
const claude = @import("claude_request.zig");
const request = @import("request.zig");

pub const AgentProvider = core.schema.AgentProvider;
pub const RequestClass = request.RequestClass;
pub const max_concurrent_requests = 128;

/// Owns the body classifier for one candidate provider request.
pub const Observer = struct {
    provider: AgentProvider = .unknown,
    claude_decoder: claude.Decoder = .{},
    active: bool = false,

    /// Initializes one observer at its final memory address.
    ///
    /// ```zig
    /// var observer: Observer = .{};
    /// observer.init(.claude);
    /// defer observer.deinit();
    /// ```
    pub fn init(observer: *Observer, provider: AgentProvider) void {
        observer.* = .{ .provider = provider, .active = true };

        if (provider == .claude) {
            observer.claude_decoder.init();
        }
    }

    /// Feeds one borrowed request-body fragment without retaining it.
    ///
    /// ```zig
    /// observer.feed(fragment.payload);
    /// ```
    pub fn feed(observer: *Observer, input: []const u8) void {
        if (!observer.active) {
            return;
        }

        switch (observer.provider) {
            .claude => observer.claude_decoder.feed(input),
            .codex, .unknown => {},
        }
    }

    /// Validates the complete body and returns its semantic classification.
    /// Unsupported and malformed request bodies fail closed as auxiliary.
    ///
    /// ```zig
    /// const classification = observer.finish();
    /// ```
    pub fn finish(observer: *Observer) RequestClass {
        if (!observer.active) {
            return .auxiliary;
        }

        return switch (observer.provider) {
            .claude => if (observer.claude_decoder.finish()) .inference else .auxiliary,
            .codex, .unknown => .auxiliary,
        };
    }

    /// Reports whether this observer currently owns a candidate body.
    ///
    /// ```zig
    /// if (observer.isActive()) {
    ///     observer.feed(fragment);
    /// }
    /// ```
    pub fn isActive(observer: *const Observer) bool {
        return observer.active;
    }

    /// Releases and erases all provider-specific parsing state.
    ///
    /// ```zig
    /// observer.deinit();
    /// ```
    pub fn deinit(observer: *Observer) void {
        if (!observer.active) {
            return;
        }

        if (observer.provider == .claude) {
            observer.claude_decoder.deinit();
        }

        observer.provider = .unknown;
        observer.active = false;
    }
};

/// One borrowed HTTP/2 request-body fragment associated with its stream.
pub const Fragment = struct {
    stream_id: u32,
    bytes: []const u8,
};

/// Bounded collection of request observers keyed by HTTP/2 stream ID.
pub const Streams = struct {
    const Slot = struct {
        stream_id: u32 = 0,
        observer: Observer = .{},
    };

    provider: AgentProvider,
    slots: [max_concurrent_requests]Slot = @splat(.{}),

    /// Creates an empty per-connection observer set.
    ///
    /// ```zig
    /// var streams = Streams.init(.claude);
    /// defer streams.deinit();
    /// ```
    pub fn init(provider: AgentProvider) Streams {
        return .{ .provider = provider };
    }

    /// Starts observing one candidate stream. Duplicate, zero, and
    /// capacity-exhausted stream IDs return `false` without replacing state.
    ///
    /// ```zig
    /// const observing = streams.start(stream_id);
    /// ```
    pub fn start(streams: *Streams, stream_id: u32) bool {
        if (stream_id == 0 or streams.provider == .unknown) {
            return false;
        }

        var free: ?*Slot = null;

        for (&streams.slots) |*slot| {
            if (slot.stream_id == stream_id) {
                return false;
            }

            if (slot.stream_id == 0 and free == null) {
                free = slot;
            }
        }

        const slot = free orelse return false;
        slot.stream_id = stream_id;
        slot.observer.init(streams.provider);
        return true;
    }

    /// Feeds a fragment to its matching stream. Unknown streams are ignored.
    ///
    /// ```zig
    /// streams.feed(.{ .stream_id = stream_id, .bytes = fragment });
    /// ```
    pub fn feed(streams: *Streams, fragment: Fragment) void {
        const slot = streams.find(fragment.stream_id) orelse return;
        slot.observer.feed(fragment.bytes);
    }

    /// Finishes and erases one stream, returning its classification when it
    /// was actively observed.
    ///
    /// ```zig
    /// if (streams.finish(stream_id)) |classification| {
    ///     publish(classification);
    /// }
    /// ```
    pub fn finish(streams: *Streams, stream_id: u32) ?RequestClass {
        const slot = streams.find(stream_id) orelse return null;
        const classification = slot.observer.finish();
        slot.observer.deinit();
        slot.* = .{};
        return classification;
    }

    /// Erases one interrupted stream without attempting classification.
    ///
    /// ```zig
    /// streams.discard(stream_id);
    /// ```
    pub fn discard(streams: *Streams, stream_id: u32) void {
        const slot = streams.find(stream_id) orelse return;
        slot.observer.deinit();
        slot.* = .{};
    }

    /// Erases every stream still owned by the connection.
    ///
    /// ```zig
    /// streams.deinit();
    /// ```
    pub fn deinit(streams: *Streams) void {
        for (&streams.slots) |*slot| {
            if (slot.stream_id == 0) {
                continue;
            }

            slot.observer.deinit();
            slot.* = .{};
        }

        streams.provider = .unknown;
    }

    fn find(streams: *Streams, stream_id: u32) ?*Slot {
        for (&streams.slots) |*slot| {
            if (slot.stream_id == stream_id) {
                return slot;
            }
        }

        return null;
    }
};

const primary_body = "{\"messages\":[],\"tools\":[{\"name\":\"Read\"}],\"stream\":true}";
const auxiliary_body = "{\"messages\":[],\"tools\":[],\"stream\":true}";

test "request observer distinguishes primary and auxiliary Claude bodies" {
    var primary: Observer = .{};
    primary.init(.claude);
    defer primary.deinit();
    primary.feed(primary_body);

    var auxiliary: Observer = .{};
    auxiliary.init(.claude);
    defer auxiliary.deinit();
    auxiliary.feed(auxiliary_body);

    try std.testing.expectEqual(RequestClass.inference, primary.finish());
    try std.testing.expectEqual(RequestClass.auxiliary, auxiliary.finish());
}

test "request streams classify arbitrarily interleaved bodies independently" {
    var streams = Streams.init(.claude);
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
    var streams = Streams.init(.claude);
    defer streams.deinit();
    try std.testing.expect(streams.start(7));
    streams.feed(.{ .stream_id = 7, .bytes = primary_body });
    try std.testing.expectEqual(RequestClass.inference, streams.finish(7).?);

    try std.testing.expect(streams.start(7));
    streams.feed(.{ .stream_id = 7, .bytes = auxiliary_body });
    try std.testing.expectEqual(RequestClass.auxiliary, streams.finish(7).?);
}

test "discarding a request stream erases partial input and releases its slot" {
    var streams = Streams.init(.claude);
    defer streams.deinit();
    try std.testing.expect(streams.start(9));
    streams.feed(.{ .stream_id = 9, .bytes = primary_body[0 .. primary_body.len / 2] });

    streams.discard(9);

    try std.testing.expect(streams.finish(9) == null);
    try std.testing.expect(streams.start(9));
}

test "request stream capacity fails closed without disturbing active slots" {
    var streams = Streams.init(.claude);
    defer streams.deinit();

    for (0..max_concurrent_requests) |index| {
        try std.testing.expect(streams.start(@intCast(index * 2 + 1)));
    }

    try std.testing.expect(!streams.start(@intCast(max_concurrent_requests * 2 + 1)));
    try std.testing.expect(!streams.start(1));
    streams.feed(.{ .stream_id = 1, .bytes = primary_body });
    try std.testing.expectEqual(RequestClass.inference, streams.finish(1).?);
}
