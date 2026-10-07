//! HTTP/2 relay with bounded HPACK observation. Every frame is forwarded byte
//! for byte; header blocks are decoded from a copy through an independent
//! inflater per direction. DATA, flow control, and stream ownership remain end
//! to end.

const h2frames = @import("h2frames");
const framing = h2frames.framing;
const Observer = @import("Observer.zig");
const header_memory = @import("header_memory.zig");
const std = @import("std");
const observer_hooks = @import("../observer_hooks.zig");

pub const c = @cImport({
    @cInclude("nghttp2/nghttp2.h");
});

pub const client_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
pub const max_header_block_bytes = 128 * 1024;

pub const frame_data: u8 = 0x0;
pub const frame_headers: u8 = 0x1;
pub const frame_rst_stream: u8 = 0x3;
pub const frame_push_promise: u8 = 0x5;
pub const frame_goaway: u8 = 0x7;
pub const frame_continuation: u8 = 0x9;

pub const flag_end_stream: u8 = 0x1;
pub const flag_end_headers: u8 = 0x4;
pub const flag_padded: u8 = 0x8;
pub const flag_priority: u8 = 0x20;

pub const Direction = enum { request, response };

pub const Stats = @import("Stats.zig");

pub const Lifecycle = @import("Lifecycle.zig");

pub const RequestBody = @import("RequestBody.zig");

pub const RequestFinished = @import("RequestFinished.zig");

pub const ResponseBody = @import("ResponseBody.zig");

const HeaderBlock = h2frames.HeaderBlock;

/// One borrowed observation produced while relaying HTTP/2 frames.
pub const Event = union(enum) {
    lifecycle: Lifecycle,
    request_headers: HeaderBlock,
    request_body: RequestBody,
    request_finished: RequestFinished,
    response_headers: HeaderBlock,
    response_body: ResponseBody,
};

pub const Route = @import("RelayRoute.zig");

pub const HeaderKind = enum { none, headers, push_promise };

/// Relays one HTTP/2 direction byte for byte while publishing decoded events.
/// A sink that declares `relayed()` hears every forwarded read, frames that
/// publish no event (PING, WINDOW_UPDATE, SETTINGS) included.
///
/// ```zig
/// const stats = relay(session, route, &sink);
/// ```
pub fn relay(session: anytype, route: Route, sink: anytype) Stats {
    var memory = header_memory.of(&route.gpa);
    var observer = Observer.init(&memory, route.watched_routes, route.direction);
    defer observer.deinit();
    var preface_offset: usize = 0;
    var buffer: [32 * 1024]u8 = undefined;
    while (true) {
        const len = session.read(route.from, &buffer) orelse break;
        var input = buffer[0..len];
        if (route.direction == .request and preface_offset < client_preface.len) {
            const take = @min(client_preface.len - preface_offset, input.len);
            if (!std.mem.eql(
                u8,
                client_preface[preface_offset..][0..take],
                input[0..take],
            )) {
                observer.fail();
            }
            preface_offset += take;
            input = input[take..];
        }

        if (route.direction == .request) {
            observer.observe(input, sink);
        }

        if (!session.writeAll(route.to, buffer[0..len])) {
            break;
        }

        if (comptime observer_hooks.declares(@TypeOf(sink), "relayed")) {
            sink.relayed();
        }

        if (route.direction == .response) {
            observer.observe(input, sink);
        }
    }
    if ((route.direction == .request and preface_offset != client_preface.len) or
        observer.framing.header_len != 0 or observer.framing.payload_left != 0 or
        observer.continuation_stream != 0)
    {
        observer.fail();
    }

    session.halfClose(route.to);
    return .{
        .decode_failed = observer.failed,
        .header_block_too_large = observer.block_too_large,
        .untracked_streams = observer.untracked_streams,
    };
}

pub fn isHeaderFrame(frame_type: u8) bool {
    return frame_type == frame_headers or
        frame_type == frame_push_promise or
        frame_type == frame_continuation;
}

fn lifecycle(event: Event) ?Lifecycle {
    return switch (event) {
        .lifecycle => |value| value,
        .request_headers => null,
        .request_body => null,
        .request_finished => null,
        .response_headers => null,
        .response_body => null,
    };
}
