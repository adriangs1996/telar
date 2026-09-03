const std = @import("std");
const Io = std.Io;
const net = std.Io.net;

const ca = @import("ca.zig");
const event = @import("event.zig");
const h2 = @import("h2.zig");
const http = @import("http.zig");
const tls = @import("tls.zig");

// HTTPS forward proxy with TLS interception.
//
// Handles CONNECT, then stops being a pipe: it terminates the child's TLS with a
// certificate minted for the requested host, opens its own verified connection
// to the real origin, and relays HTTP/1.1 in the clear between the two.
//
// Credentials never become storable text — `http.redactedHead` drops them while
// building the record, not afterwards.

/// Reserves a loopback port with plain syscalls, before any `Io` task exists.
/// Called before the fork so `HTTPS_PROXY` can be exported to the child, and
/// kept syscall-only so no worker thread is alive across the fork.
pub fn reservePort(first: u16, count: u16) ?u16 {
    var port = first;
    while (port < first + count) : (port += 1) {
        const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (fd < 0) {
            return null;
        }
        defer _ = std.c.close(fd);

        var addr: std.c.sockaddr.in = .{
            .family = std.c.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = 0x0100007f, // 127.0.0.1, network order
            .zero = @splat(0),
        };
        const rc = std.c.bind(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in));
        if (rc == 0) {
            return port;
        }
    }
    return null;
}

/// Accepts tunnels until cancelled. One task per connection.
pub const ServeContext = struct {
    io: Io,
    port: u16,
    authority: ca.Authority,
    allocator: std.mem.Allocator,
    queue: *event.Queue,
};

pub fn serve(context: ServeContext) Io.Cancelable!void {
    const io = context.io;
    const port = context.port;
    const authority = context.authority;
    const gpa = context.allocator;
    const queue = context.queue;
    const address = net.IpAddress.parse("127.0.0.1", port) catch return;
    var server = address.listen(io, .{ .reuse_address = true }) catch return;
    defer server.deinit(io);

    // The platform's real roots, read once. Every connection wants the same
    // answer, and rescanning per connection costs an allocation and a few
    // milliseconds on the handshake path.
    var roots = tls.Roots.load(io, gpa) catch return;
    defer roots.deinit(gpa);

    var connections: Io.Group = .init;
    defer connections.cancel(io);

    var next_id: std.atomic.Value(u64) = .init(1);

    while (true) {
        const stream = server.accept(io) catch |err| switch (err) {
            error.Canceled => |e| return e,
            // A single failed accept is not fatal; a listener that has gone
            // away is.
            error.SocketNotListening => return,
            else => continue,
        };

        connections.concurrent(io, tunnel, .{ io, stream, authority, roots, gpa, queue, &next_id }) catch {
            stream.close(io);
        };
    }
}

fn tunnel(io: Io, stream: net.Stream, authority: ca.Authority, roots: tls.Roots, gpa: std.mem.Allocator, queue: *event.Queue, next_id: *std.atomic.Value(u64)) Io.Cancelable!void {
    defer stream.close(io);

    var head_buf: [8 * event.KB]u8 = undefined;
    var client_reader = stream.reader(io, &head_buf);

    // First line: METHOD target HTTP/x.y. Copy it out before draining the rest
    // of the header, since later reads reuse the same buffer.
    var line_buf: [1024]u8 = undefined;
    const request_line = blk: {
        const raw = client_reader.interface.takeDelimiterInclusive('\n') catch return;
        const line = std.mem.trimEnd(u8, raw, "\r\n");
        if (line.len > line_buf.len) {
            return;
        }
        @memcpy(line_buf[0..line.len], line);
        break :blk line_buf[0..line.len];
    };

    while (true) {
        const line = client_reader.interface.takeDelimiterInclusive('\n') catch return;
        if (std.mem.eql(u8, line, "\r\n") or std.mem.eql(u8, line, "\n")) {
            break;
        }
    }

    var parts = std.mem.tokenizeScalar(u8, request_line, ' ');
    const method = parts.next() orelse return;
    const target = parts.next() orelse return;
    if (!std.mem.eql(u8, method, "CONNECT")) {
        return;
    }

    const colon = std.mem.lastIndexOfScalar(u8, target, ':') orelse return;
    const host = target[0..colon];
    const port = std.fmt.parseInt(u16, target[colon + 1 ..], 10) catch 443;

    var cw_buf: [16 * event.KB]u8 = undefined;
    var client_writer = stream.writer(io, &cw_buf);

    const host_name = net.HostName.init(host) catch {
        reply(&client_writer.interface, "HTTP/1.1 502 Bad Gateway\r\n\r\n");
        return;
    };
    const upstream = connectUpstream(host_name, io, port) catch {
        reply(&client_writer.interface, "HTTP/1.1 502 Bad Gateway\r\n\r\n");
        return;
    };
    defer upstream.close(io);

    client_writer.interface.writeAll("HTTP/1.1 200 Connection Established\r\n\r\n") catch return;
    client_writer.interface.flush() catch return;

    // The buffered reader must not have swallowed any of the ClientHello. In
    // practice clients wait for this 200 before sending it, so an assertion is
    // enough; a memory BIO would be the fix if that ever stopped holding.
    if (client_reader.interface.buffered().len != 0) {
        return;
    }

    const id = next_id.fetchAdd(1, .monotonic);
    const opened_at = Io.Timestamp.now(io, .awake);

    var opened: event.Upstream = .{ .id = id, .host = .{}, .port = port };
    opened.host.set(host);
    queue.putOne(io, .{ .upstream_opened = opened }) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => {},
    };

    // ---- kept for clients that negotiate no ALPN at all
    if (false) {
        var blind_up: std.atomic.Value(u64) = .init(0);
        var blind_down: std.atomic.Value(u64) = .init(0);
        const client_fd = stream.socket.handle;
        const origin_fd = upstream.socket.handle;

        if (io.concurrent(pumpBlind, .{ client_fd, origin_fd, &blind_up })) |future| {
            var c2o = future;
            pumpBlind(origin_fd, client_fd, &blind_down);
            c2o.await(io);
        } else |_| {
            pumpBlind(origin_fd, client_fd, &blind_down);
        }

        queue.putOne(io, .{ .upstream_exchange = .{
            .id = id,
            .host = opened.host,
            .port = port,
            .request_bytes = blind_up.load(.monotonic),
            .response_bytes = blind_down.load(.monotonic),
            .duration_ms = opened_at.durationTo(Io.Timestamp.now(io, .awake)).toMilliseconds(),
            .detail = gpa.dupe(u8, "not intercepted: client did not offer http/1.1 (likely h2)") catch null,
        } }) catch {};
        return;
    }

    // ---- terminate both ends and sit in the middle
    var cause: anyerror = error.Unknown;
    const session = tls.intercept(
        io,
        gpa,
        authority,
        roots,
        host,
        stream,
        upstream,
        &cause,
    ) catch |err| {
        // A failed handshake is the interesting failure, and which end refused
        // is the diagnosis, so record it rather than dropping it.
        var note_buf: [768]u8 = undefined;
        const note = std.fmt.bufPrint(&note_buf, "intercept failed: {s}: {s}{s}{s}", .{
            @errorName(err),
            @errorName(cause),
            if (tls.explain(cause) != null) " - " else "",
            tls.explain(cause) orelse "",
        }) catch "intercept failed";
        queue.putOne(io, .{ .upstream_exchange = .{
            .id = id,
            .host = opened.host,
            .port = port,
            .request_bytes = 0,
            .response_bytes = 0,
            .duration_ms = opened_at.durationTo(Io.Timestamp.now(io, .awake)).toMilliseconds(),
            .detail = gpa.dupe(u8, note) catch null,
        } }) catch {};
        return;
    };
    defer session.deinit();

    // ---- HTTP/2 takes a different shape: streams interleave, so both
    // directions run at once and there is no request/response turn to hang the
    // half-duplex loop on.
    if (session.negotiated() == .h2) {
        relayH2(io, session, gpa, id, opened, port, queue) catch |err| switch (err) {
            error.Canceled => |e| return e,
        };
        return;
    }

    var msg_buf: [16 * event.KB]u8 = undefined;
    var req_head: [16 * event.KB]u8 = undefined;
    var req_body: [32 * event.KB]u8 = undefined;
    var res_body: [64 * event.KB]u8 = undefined;

    var total_up: u64 = 0;
    var total_down: u64 = 0;

    // HTTP/1.1 keep-alive: one request and one response per turn, until either
    // side stops talking.
    while (true) {
        const started = Io.Timestamp.now(io, .awake);

        const request = http.relay(session, .{ .from = .child, .to = .origin, .is_response = false }, .{ .scratch = &msg_buf, .capture = &req_body }) orelse break;
        // Both the head and the body capture live in buffers the response relay
        // is about to reuse, so copy what has to survive it.
        @memcpy(req_head[0..request.head.len], request.head);
        const request_head = req_head[0..request.head.len];
        const request_body = req_body[0..request.body.len];
        const req_bytes = request.body_bytes;
        const req_truncated = request.truncated;

        const response = http.relay(session, .{ .from = .origin, .to = .child, .is_response = true }, .{ .scratch = &msg_buf, .capture = &res_body }) orelse break;

        total_up += req_bytes;
        total_down += response.body_bytes;

        const detail = renderExchange(
            gpa,
            request_head,
            request_body,
            response.head,
            response.body,
        );

        const exchange: event.Event = .{ .upstream_exchange = .{
            .id = id,
            .host = opened.host,
            .port = port,
            .request_bytes = req_bytes,
            .response_bytes = response.body_bytes,
            .duration_ms = started.durationTo(Io.Timestamp.now(io, .awake)).toMilliseconds(),
            .detail = detail,
            .truncated = req_truncated or response.truncated,
        } };

        queue.putOne(io, exchange) catch |err| {
            if (detail) |owned| {
                gpa.free(owned);
            }
            switch (err) {
                error.Canceled => |e| return e,
                else => return,
            }
        };

        // A 101 ends HTTP framing: the connection becomes full duplex and both
        // peers may speak at once. Codex takes this path for its model stream,
        // and the half-duplex loop would deadlock waiting for a request that is
        // never coming. Frames are not decoded; the record keeps the upgrade
        // itself and the volume that followed.
        if (std.mem.indexOf(u8, response.start_line, " 101 ") != null) {
            var ws_up: std.atomic.Value(u64) = .init(0);
            var ws_down: std.atomic.Value(u64) = .init(0);

            if (io.concurrent(pumpDirection, .{ session, .child, .origin, &ws_up })) |future| {
                var c2o = future;
                pumpDirection(session, .origin, .child, &ws_down);
                c2o.await(io);
            } else |_| {
                pumpDirection(session, .origin, .child, &ws_down);
            }

            total_up += ws_up.load(.monotonic);
            total_down += ws_down.load(.monotonic);
            break;
        }
    }

    const elapsed = opened_at.durationTo(Io.Timestamp.now(io, .awake));
    queue.putOne(io, .{ .upstream_closed = .{
        .id = id,
        .bytes_up = total_up,
        .bytes_down = total_down,
        .duration_ms = elapsed.toMilliseconds(),
    } }) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => {},
    };
}

/// Everything one direction of an h2 connection reported.
const H2Side = struct {
    decoder: h2.Decoder,
    text: std.Io.Writer.Allocating,
    body: []u8,
    body_len: usize = 0,
    seen: h2.Observed = .{},

    fn run(self: *H2Side, session: *tls.Session, from: tls.Session.Side, to: tls.Session.Side) void {
        h2.relay(session, .{ .from = from, .to = to }, .{
            .decoder = &self.decoder,
            .text = &self.text.writer,
            .body = self.body,
            .body_len = &self.body_len,
            .seen = &self.seen,
        });
        // One side stopping ends the conversation; release the other so the
        // exchange gets recorded instead of waiting on a keep-alive timeout.
        session.halfClose(to);
    }
};

/// Runs both directions of an h2 connection and records one exchange for the
/// whole thing. Per-stream splitting is the next step; this is the connection.
fn relayH2(io: Io, session: *tls.Session, gpa: std.mem.Allocator, id: u64, opened: event.Upstream, port: u16, queue: *event.Queue) Io.Cancelable!void {
    const started = Io.Timestamp.now(io, .awake);

    const req_body = gpa.alloc(u8, 64 * event.KB) catch return;
    defer gpa.free(req_body);
    const res_body = gpa.alloc(u8, 128 * event.KB) catch return;
    defer gpa.free(res_body);

    var out: H2Side = .{
        .decoder = h2.Decoder.init(gpa) catch return,
        .text = .init(gpa),
        .body = req_body,
    };
    defer out.decoder.deinit();
    defer out.text.deinit();

    var back: H2Side = .{
        .decoder = h2.Decoder.init(gpa) catch return,
        .text = .init(gpa),
        .body = res_body,
    };
    defer back.decoder.deinit();
    defer back.text.deinit();

    if (io.concurrent(H2Side.run, .{ &out, session, .child, .origin })) |future| {
        var c2o = future;
        back.run(session, .origin, .child);
        c2o.await(io);
    } else |_| {
        back.run(session, .origin, .child);
    }

    const detail = renderH2(gpa, &out, &back);
    queue.putOne(io, .{ .upstream_exchange = .{
        .id = id,
        .host = opened.host,
        .port = port,
        .request_bytes = out.seen.data_bytes,
        .response_bytes = back.seen.data_bytes,
        .duration_ms = started.durationTo(Io.Timestamp.now(io, .awake)).toMilliseconds(),
        .detail = detail,
        .truncated = out.seen.truncated or back.seen.truncated,
    } }) catch |err| {
        if (detail) |owned| {
            gpa.free(owned);
        }
        switch (err) {
            error.Canceled => |e| return e,
            else => return,
        }
    };
}

fn renderH2(gpa: std.mem.Allocator, out: *H2Side, back: *H2Side) ?[]const u8 {
    var w: std.Io.Writer.Allocating = .init(gpa);
    errdefer w.deinit();

    w.writer.print("HTTP/2 · {d} frames out, {d} back\n", .{ out.seen.frames, back.seen.frames }) catch return null;
    w.writer.writeAll("\n=== request ===\n") catch return null;
    // Header names come from HPACK, so credentials arrive decoded and must be
    // dropped here exactly as in the HTTP/1.1 path.
    http.redactedHead(out.text.written(), &w.writer) catch return null;
    if (out.body_len > 0) {
        w.writer.print("\n{s}\n", .{out.body[0..out.body_len]}) catch return null;
    }

    w.writer.writeAll("\n=== response ===\n") catch return null;
    http.redactedHead(back.text.written(), &w.writer) catch return null;
    if (back.body_len > 0) {
        w.writer.print("\n{s}\n", .{back.body[0..back.body_len]}) catch return null;
    }

    return w.toOwnedSlice() catch null;
}

/// Peeks the ClientHello without consuming it, to decide whether this
/// connection can be intercepted at all.
///
/// The proxy only speaks HTTP/1.1. A client that offers just `h2` completes the
/// handshake fine and then talks in frames this relay cannot read, so the
/// connection stalls until the peer's keepalive gives up — the agent breaks
/// because *we* could not follow. Deciding before terminating TLS turns that
/// into a blind tunnel instead.
///
/// Crude on purpose: a real implementation parses the ALPN extension. Searching
/// the ClientHello for the literal protocol name is enough for a PoC, and errs
/// towards not intercepting when it cannot tell.
fn clientOffersHttp11(fd: c_int) bool {
    const MSG_PEEK: c_int = 0x2;
    var buf: [4 * event.KB]u8 = undefined;
    const n = std.c.recv(fd, &buf, buf.len, MSG_PEEK);
    if (n <= 0) {
        return false;
    }
    return std.mem.indexOf(u8, buf[0..@intCast(n)], "http/1.1") != null;
}

/// Copies one direction of a still-encrypted connection. Used when the client
/// speaks a protocol the relay cannot read.
fn pumpBlind(from: c_int, to: c_int, counter: *std.atomic.Value(u64)) void {
    var buf: [16 * event.KB]u8 = undefined;
    while (true) {
        const n = std.c.read(from, &buf, buf.len);
        if (n <= 0) {
            break;
        }
        var sent: usize = 0;
        while (sent < @as(usize, @intCast(n))) {
            const w = std.c.write(to, buf[sent..].ptr, @as(usize, @intCast(n)) - sent);
            if (w <= 0) {
                return;
            }
            sent += @intCast(w);
        }
        _ = counter.fetchAdd(@intCast(n), .monotonic);
    }
}

/// Copies one direction opaquely until it stops. Each `SSL` object ends up with
/// exactly one reading thread and one writing thread, which is the pairing
/// OpenSSL supports on a single object.
fn pumpDirection(session: *tls.Session, from: tls.Session.Side, to: tls.Session.Side, counter: *std.atomic.Value(u64)) void {
    var buf: [16 * event.KB]u8 = undefined;
    while (true) {
        const n = session.read(from, &buf) orelse break;
        if (!session.writeAll(to, buf[0..n])) {
            break;
        }
        _ = counter.fetchAdd(n, .monotonic);
    }
}

/// Builds the storable rendering of one exchange. Bodies are deliberately not
/// persisted: prompts, replies, and tool payloads may contain credentials for
/// which no generic redactor can provide a safety guarantee.
fn renderExchange(gpa: std.mem.Allocator, request_head: []const u8, request_body: []const u8, response_head: []const u8, response_body: []const u8) ?[]const u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();

    http.redactedHead(request_head, &out.writer) catch return null;
    if (request_body.len > 0) {
        out.writer.print("\n<body omitted: {d} bytes>\n", .{request_body.len}) catch return null;
    }
    out.writer.writeAll("\n--- response ---\n") catch return null;
    http.redactedHead(response_head, &out.writer) catch return null;
    if (response_body.len > 0) {
        out.writer.print("\n<body omitted: {d} bytes>\n", .{response_body.len}) catch return null;
    }

    return out.toOwnedSlice() catch null;
}

test "storable exchanges omit request and response bodies" {
    const rendered = renderExchange(
        std.testing.allocator,
        "POST / HTTP/1.1\r\nAuthorization: bearer secret\r\n\r\n",
        "request-api-key",
        "HTTP/1.1 200 OK\r\n\r\n",
        "response-api-key",
    ).?;
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "bearer secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "request-api-key") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "response-api-key") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "<body omitted: 15 bytes>") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "<body omitted: 16 bytes>") != null);
}

// HostName.connect races connection attempts for all resolved addresses. On
// Zig 0.16.0/macOS that path can panic when a racing connect(2) reports
// EISCONN, so resolve asynchronously but try addresses one at a time.
fn connectUpstream(host_name: net.HostName, io: Io, port: u16) !net.Stream {
    var lookup_buf: [32]net.HostName.LookupResult = undefined;
    var resolved: Io.Queue(net.HostName.LookupResult) = .init(&lookup_buf);
    var lookup_future = io.async(net.HostName.lookup, .{ host_name, io, &resolved, .{ .port = port } });
    defer lookup_future.cancel(io) catch {};

    var last_connect_error: ?anyerror = null;
    while (resolved.getOne(io)) |result| switch (result) {
        .canonical_name => continue,
        .address => |address| {
            if (address.connect(io, .{ .mode = .stream })) |stream| {
                return stream;
            } else |err| {
                last_connect_error = err;
            }
        },
    } else |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.Closed => {
            try lookup_future.await(io);
            return last_connect_error orelse error.UnknownHostName;
        },
    }
}

fn pump(io: Io, r: *Io.Reader, w: *Io.Writer, dst: net.Stream, counter: *std.atomic.Value(u64)) void {
    while (true) {
        const n = r.stream(w, .unlimited) catch break;
        _ = counter.fetchAdd(n, .monotonic);
        w.flush() catch break;
    }
    dst.shutdown(io, .send) catch {};
}

fn reply(w: *Io.Writer, bytes: []const u8) void {
    w.writeAll(bytes) catch return;
    w.flush() catch {};
}
