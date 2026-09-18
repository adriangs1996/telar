const std = @import("std");
const core = @import("telar-core");
const Request = @import("HistoryRequest.zig");
const Position = @import("HistoryPosition.zig");
const Stream = @import("Stream.zig");
const protocol = @import("protocol.zig");
const history_page = @import("history_page.zig");
const ProviderHistory = @This();

pub const max_response_bytes = 2 * 1024 * 1024;
pub const max_json_bytes = 8 * 1024 * 1024;
pub const max_scanned_items = 4096;

io: std.Io,
gpa: std.mem.Allocator,
request_value: Request,
result: anyerror!*core.AgentHistoryPage = error.Canceled,
stream: Stream = undefined,
input: std.Io.File = undefined,
json: std.heap.FixedBufferAllocator = undefined,
body: []u8 = undefined,
next_request: i64 = 1,
write_buffer: [8192]u8 = undefined,

/// Reads one disposable history window in an isolated app-server process. All
/// request memory is borrowed until return; callers own the returned page.
/// Example: `const page = try ProviderHistory.read(io, gpa, request);`
pub fn read(io: std.Io, gpa: std.mem.Allocator, request_value: Request) !*core.AgentHistoryPage {
    if (request_value.thread_id.len == 0 or request_value.thread_id.len > 128 or !std.unicode.utf8ValidateSlice(request_value.thread_id) or std.mem.indexOfScalar(u8, request_value.thread_id, 0) != null) {
        return error.InvalidHistoryThread;
    }

    const task = try gpa.create(ProviderHistory);
    defer gpa.destroy(task);
    task.* = .{ .io = io, .gpa = gpa, .request_value = request_value };
    var adopted = false;
    defer if (!adopted) {
        if (task.result) |page| {
            gpa.destroy(page);
        } else |_| {}
    };
    const Result = union(enum) { finished: void, timeout: anyerror!void };
    var events: [2]Result = undefined;
    var select: std.Io.Select(Result) = .init(io, &events);
    defer select.cancelDiscard();
    try select.concurrent(.finished, execute, .{task});
    try select.concurrent(.timeout, deadline, .{task});
    switch (try select.await()) {
        .finished => {
            const page = try task.result;
            adopted = true;
            return page;
        },
        .timeout => |value| {
            try value;
            return error.HistoryTimeout;
        },
    }
}

fn execute(task: *ProviderHistory) void {
    task.result = task.exchange();
}

fn deadline(task: *ProviderHistory) !void {
    try task.io.sleep(.fromMilliseconds(task.request_value.options.timeout_ms), .awake);
}

fn exchange(task: *ProviderHistory) !*core.AgentHistoryPage {
    const options = task.request_value.options;
    const response = try task.gpa.alloc(u8, max_response_bytes);
    defer task.gpa.free(response);
    const json = try task.gpa.alloc(u8, max_json_bytes);
    defer task.gpa.free(json);
    task.json = .init(json);
    task.body = try task.gpa.alloc(u8, max_response_bytes);
    defer task.gpa.free(task.body);
    var child = try std.process.spawn(task.io, .{
        .argv = options.arguments,
        .cwd = .{ .path = options.cwd },
        .environ_map = &options.environment,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
        .pgid = 0,
    });
    defer {
        if (child.id) |pid| {
            std.posix.kill(-pid, .KILL) catch {};
        }

        child.kill(task.io);
    }

    task.stream = .{ .file = child.stdout.?, .external_line = response };
    task.input = child.stdin.?;
    _ = try task.rpc("initialize", .{
        .clientInfo = .{ .name = "telar_history", .version = "0.1.0" },
        .capabilities = .{ .experimentalApi = true },
    });
    try task.input.writeStreamingAll(task.io, "{\"method\":\"initialized\"}\n");
    const metadata = try task.rpc("thread/read", .{ .threadId = task.request_value.thread_id, .includeTurns = false });
    const thread = protocol.field(metadata, "thread");
    if (!protocol.is(protocol.field(thread, "id"), task.request_value.thread_id)) {
        return error.InvalidHistoryThread;
    }
    if (!protocol.is(protocol.field(thread, "historyMode"), "paginated")) {
        return task.loadLegacyPage();
    }

    return task.loadPage();
}

fn rpc(task: *ProviderHistory, method: []const u8, params: anytype) !std.json.Value {
    const id = task.next_request;
    task.next_request += 1;
    const bytes = protocol.encode(&task.write_buffer, .{ .id = id, .method = method, .params = params }) catch return error.HistoryCursorTooLarge;
    try task.input.writeStreamingAll(task.io, bytes);
    var skipped: usize = 0;
    while (skipped < 256) : (skipped += 1) {
        const line = task.stream.next(task.io) catch |err| return if (err == error.ProviderFrameTooLarge) error.HistoryResponseTooLarge else err;
        task.json.reset();
        const value = std.json.parseFromSliceLeaky(std.json.Value, task.json.allocator(), line, .{ .max_value_len = max_response_bytes }) catch return error.InvalidHistoryResponse;
        const returned_id = protocol.field(value, "id");
        if (protocol.field(value, "method") == .string) {
            if (returned_id != .null) {
                return error.UnexpectedHistoryServerRequest;
            }

            continue;
        }
        if (returned_id != .integer or returned_id.integer != id) {
            return error.InvalidHistoryResponse;
        }
        if (protocol.field(value, "error") != .null) {
            const code = protocol.field(protocol.field(value, "error"), "code");
            return if (code == .integer and code.integer == -32601) error.HistoryPaginationUnsupported else error.ProviderHistoryRejected;
        }

        const result = protocol.field(value, "result");
        if (result != .object) {
            return error.InvalidHistoryResponse;
        }

        return result;
    }

    return error.HistoryNotificationLimit;
}

fn loadLegacyPage(task: *ProviderHistory) !*core.AgentHistoryPage {
    const result = try task.rpc("thread/read", .{ .threadId = task.request_value.thread_id, .includeTurns = true });
    const thread = protocol.field(result, "thread");
    if (!protocol.is(protocol.field(thread, "id"), task.request_value.thread_id)) {
        return error.InvalidHistoryThread;
    }

    const history = try task.gpa.create(@import("LegacyHistory.zig"));
    defer task.gpa.destroy(history);
    history.* = .{ .body = task.body, .query = task.request_value.query };
    try history.load(thread);
    const output = try task.gpa.create(core.AgentHistoryPage);
    errdefer task.gpa.destroy(output);
    const query = task.request_value.query;
    output.* = .{ .request_id = query.request_id, .view_generation = query.view_generation, .snapshot = .{ .pane_id = query.pane_id, .pane_generation = query.pane_generation, .status = .ready, .revision = query.view_generation } };
    const id = task.request_value.thread_id;
    @memcpy(output.snapshot.thread_id[0..id.len], id);
    output.snapshot.thread_id_len = @intCast(id.len);
    try history.fill(output, id);
    return output;
}

fn loadPage(task: *ProviderHistory) !*core.AgentHistoryPage {
    const query = task.request_value.query;
    const thread = task.request_value.thread_id;
    const output = try task.gpa.create(core.AgentHistoryPage);
    errdefer task.gpa.destroy(output);
    output.* = .{
        .request_id = query.request_id,
        .view_generation = query.view_generation,
        .snapshot = .{ .pane_id = query.pane_id, .pane_generation = query.pane_generation, .status = .ready, .revision = query.view_generation },
    };
    @memcpy(output.snapshot.thread_id[0..thread.len], thread);
    output.snapshot.thread_id_len = @intCast(thread.len);
    var position: ?Position = if (query.cursor.len != 0) try Position.decode(query.cursor, thread) else null;
    var cursor: core.AgentHistoryCursor = if (position) |boundary| boundary.provider else .{};
    var seeking = query.anchor.len != 0;
    var scanned: usize = 0;
    const older = query.direction == .older;
    if (seeking and !older) {
        return error.InvalidHistoryCursor;
    }

    while (scanned < max_scanned_items) : (scanned += 1) {
        const response = try task.rpc("thread/items/list", .{
            .threadId = thread,
            .cursor = if (cursor.len == 0) @as(?[]const u8, null) else cursor.slice(),
            .limit = 1,
            .sortDirection = if (older) @as([]const u8, "desc") else "asc",
        });
        const data = protocol.field(response, "data");
        if (data != .array or data.array.items.len > 1) {
            return error.InvalidHistoryResponse;
        }
        if (data.array.items.len == 0) {
            if (seeking) {
                return error.HistoryAnchorUnavailable;
            }

            break;
        }

        const entry = data.array.items[0];
        const raw_item = protocol.field(entry, "item");
        const source = protocol.string(protocol.field(raw_item, "id"));
        const turn = protocol.string(protocol.field(entry, "turnId"));
        if (turn.len == 0 or turn.len > 128 or !std.unicode.utf8ValidateSlice(turn) or std.mem.indexOfScalar(u8, turn, 0) != null) {
            return error.InvalidHistoryItem;
        }

        var anchor: Position = .{ .provider = try responseCursor(response, "backwardsCursor") };
        try anchor.setSource(source, turn);
        if (anchor.provider.len == 0) {
            return error.InvalidHistoryResponse;
        }

        const next = try responseCursor(response, "nextCursor");
        if (next.len != 0 and std.mem.eql(u8, cursor.slice(), next.slice())) {
            return error.RepeatedHistoryCursor;
        }
        if (seeking) {
            seeking = !std.mem.eql(u8, source, query.anchor) or !std.mem.eql(u8, turn, query.anchor_turn);
            if (next.len == 0) {
                if (seeking) {
                    return error.HistoryAnchorUnavailable;
                }

                break;
            }

            cursor = next;
            continue;
        }

        var normalizer: @import("ItemNormalizer.zig") = .{ .body_buffer = task.body, .include_history_details = true };
        var update = try @import("historical_item.zig").normalize(&normalizer, raw_item);
        if (update.truncated) {
            return error.HistoryItemNotRepresentable;
        }
        if (!std.unicode.utf8ValidateSlice(update.text)) {
            return error.InvalidHistoryItem;
        }

        update.turn_identity = std.hash.Wyhash.hash(0, turn) | 1;
        update.source_turn = turn;
        var start: usize = 0;
        var end: usize = update.text.len;
        if (position) |boundary| {
            if (!std.mem.eql(u8, source, boundary.source[0..boundary.source_len]) or !std.mem.eql(u8, turn, boundary.turn[0..boundary.turn_len]) or boundary.offset > end or !std.unicode.utf8ValidateSlice(update.text[0..boundary.offset])) {
                return error.HistoryAnchorUnavailable;
            }

            if (older) {
                end = boundary.offset;
            } else {
                start = boundary.offset;
            }
            if (start == end and (update.text.len != 0 or boundary.after == !older)) {
                position = null;
                if (next.len == 0) {
                    break;
                }

                cursor = next;
                continue;
            }

            position = null;
        }

        const available = core.agent_thread.max_text_bytes - output.snapshot.text_len;
        if (end - start > available and output.snapshot.item_count != 0) {
            break;
        }
        if (older) {
            start = end -| available;
            while (start < end and update.text[start] & 0xc0 == 0x80) {
                start += 1;
            }
        } else {
            end = start + utf8Prefix(update.text[start..end], available);
        }
        if (!try history_page.append(&output.snapshot, update, .{ start, end })) {
            break;
        }

        var before = anchor;
        before.offset = @intCast(start);
        before.after = false;
        var after = anchor;
        after.offset = @intCast(end);
        after.after = true;
        if (output.snapshot.item_count == 1) {
            output.before = try before.encode(thread);
            output.after = try after.encode(thread);
            output.has_before = if (older) next.len != 0 or start != 0 else query.cursor.len != 0 or start != 0;
            output.has_after = if (older) query.cursor.len != 0 or query.anchor.len != 0 or end != update.text.len else next.len != 0 or end != update.text.len;
        } else if (older) {
            output.before = try before.encode(thread);
            output.has_before = next.len != 0 or start != 0;
        } else {
            output.after = try after.encode(thread);
            output.has_after = next.len != 0 or end != update.text.len;
        }
        if ((older and start != 0) or (!older and end != update.text.len) or next.len == 0 or output.snapshot.item_count == core.agent_thread.max_items or output.snapshot.text_len == core.agent_thread.max_text_bytes) {
            break;
        }

        cursor = next;
    }

    if (scanned == max_scanned_items) {
        return error.HistoryScanLimit;
    }
    if (older) {
        std.mem.reverse(core.AgentThreadItem, output.snapshot.item_storage[0..output.snapshot.item_count]);
    }

    return output;
}

fn responseCursor(value: std.json.Value, field: []const u8) !core.AgentHistoryCursor {
    const cursor = protocol.field(value, field);
    return switch (cursor) {
        .null => .{},
        .string => try core.AgentHistoryCursor.init(cursor.string),
        else => error.InvalidHistoryResponse,
    };
}

fn utf8Prefix(text: []const u8, maximum: usize) usize {
    var end = @min(text.len, maximum);
    while (end < text.len and end != 0 and text[end] & 0xc0 == 0x80) {
        end -= 1;
    }

    return end;
}

test {
    _ = @import("history_test.zig");
}
