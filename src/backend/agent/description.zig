//! Bounded capture and validation for generated agent-session descriptions.
//!
//! Prompts are transient observation data. They never enter history storage,
//! process arguments, or the interactive path's allocator.

const std = @import("std");
const core = @import("telar-core");
const escape = @import("../history/escape.zig");
const pane_mod = @import("../pane/root.zig");

const schema = core.schema;

pub const max_query_bytes = 4096;
pub const max_pending_jobs = 8;
pub const max_generator_output_bytes = 512;

pub const Command = struct {
    arguments: []const []const u8,
    timeout_ms: u32,
};

pub const Generation = struct {
    command: Command,
    job: Job,
};

pub const Capture = struct {
    scanner: escape.InputScanner = .{},
    bytes: [max_query_bytes]u8 = undefined,
    len: u16 = 0,
    truncated: bool = false,
    submitted: bool = false,

    /// Returns true exactly once, when the first non-cancelled submit lands.
    pub fn feed(capture: *Capture, input: []const u8) bool {
        if (capture.submitted) return false;
        for (input) |byte| {
            if (capture.len < capture.bytes.len) {
                capture.bytes[capture.len] = byte;
                capture.len += 1;
            } else {
                capture.truncated = true;
            }
            const event = capture.scanner.feed(&.{byte});
            if (event.cancelled) {
                capture.clear();
                continue;
            }
            if (event.submitted) {
                capture.submitted = true;
                return true;
            }
        }
        return false;
    }

    pub fn raw(capture: *const Capture) []const u8 {
        return capture.bytes[0..capture.len];
    }

    pub fn clear(capture: *Capture) void {
        std.crypto.secureZero(u8, capture.bytes[0..capture.len]);
        capture.* = .{};
    }
};

pub const Job = struct {
    pane: pane_mod.PaneKey,
    session_id: [16]u8,
    provider: schema.AgentProvider,
    query: [max_query_bytes]u8 = undefined,
    query_len: u16,

    pub fn querySlice(job: *const Job) []const u8 {
        return job.query[0..job.query_len];
    }
};

pub const ResultStatus = enum {
    success,
    unavailable,
    timeout,
    invalid_output,
    failed,
};

pub const Result = struct {
    pane: pane_mod.PaneKey,
    session_id: [16]u8,
    status: ResultStatus,
    title: [schema.max_agent_session_title_bytes]u8 = undefined,
    title_len: u8 = 0,

    pub fn titleSlice(result: *const Result) []const u8 {
        return result.title[0..result.title_len];
    }
};

/// Runs one bounded title-generation subprocess and returns a validated,
/// fixed-size result without retaining the captured prompt.
///
/// ```zig
/// const result = generate(io, gpa, .{ .command = command, .job = job });
/// ```
pub fn generate(io: std.Io, gpa: std.mem.Allocator, generation: Generation) Result {
    const command = generation.command;
    var job = generation.job;
    defer std.crypto.secureZero(u8, &job.query);
    var result: Result = .{
        .pane = job.pane,
        .session_id = job.session_id,
        .status = .failed,
    };
    if (command.arguments.len == 0) {
        result.status = .unavailable;
        return result;
    }

    var child = std.process.spawn(io, .{
        .argv = command.arguments,
        // Keep generator CLIs away from the observed repository. Any model,
        // effort, profile, or trust flags are explicit argv from Lua.
        .cwd = .{ .path = "/" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch |err| {
        result.status = switch (err) {
            error.FileNotFound => .unavailable,
            else => .failed,
        };
        return result;
    };
    defer child.kill(io);

    const prompt_prefix =
        "Create a short session title for the user request below. " ++
        "Return exactly one plain-text line, no quotes, labels, markdown, or explanation. " ++
        "Use at most 48 display characters. Do not execute tools.\n\nUser request:\n";
    const input = child.stdin.?;
    input.writeStreamingAll(io, prompt_prefix) catch return result;
    input.writeStreamingAll(io, job.querySlice()) catch return result;
    input.writeStreamingAll(io, "\n") catch return result;
    input.close(io);
    child.stdin = null;

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(1) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(gpa, io, multi_reader_buffer.toStreams(), &.{child.stdout.?});
    defer multi_reader.deinit();
    const stdout_reader = multi_reader.reader(0);
    const timeout: std.Io.Timeout = .{ .deadline = .fromNow(io, .{
        .clock = .awake,
        .raw = .fromMilliseconds(command.timeout_ms),
    }) };
    while (multi_reader.fill(128, timeout)) |_| {
        if (stdout_reader.buffered().len > max_generator_output_bytes) {
            result.status = .invalid_output;
            return result;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.Timeout => {
            result.status = .timeout;
            return result;
        },
        else => return result,
    }
    multi_reader.checkAnyError() catch return result;
    if (stdout_reader.buffered().len > max_generator_output_bytes) {
        result.status = .invalid_output;
        return result;
    }
    const term = child.wait(io) catch return result;
    if (term != .exited or term.exited != 0) return result;

    const title = normalizeTitle(stdout_reader.buffered(), &result.title) catch {
        result.status = .invalid_output;
        return result;
    };
    result.title_len = @intCast(title.len);
    result.status = .success;
    return result;
}

/// Applies terminal editing controls and strips transport escape sequences.
/// The output is one trimmed line suitable for the fixed generator prompt.
pub fn normalizeQuery(raw: []const u8, output: *[max_query_bytes]u8) ![]const u8 {
    var output_len: usize = 0;
    var index: usize = 0;
    var paste = false;
    while (index < raw.len) {
        if (std.mem.startsWith(u8, raw[index..], "\x1b[200~")) {
            paste = true;
            index += 6;
            continue;
        }
        if (std.mem.startsWith(u8, raw[index..], "\x1b[201~")) {
            paste = false;
            index += 6;
            continue;
        }
        const byte = raw[index];
        if (byte == 0x1b) {
            index = skipEscape(raw, index);
            continue;
        }
        switch (byte) {
            '\r', '\n' => {
                index += 1;
                if (!paste) break;
                try appendSpace(output, &output_len);
            },
            '\t' => {
                index += 1;
                try appendSpace(output, &output_len);
            },
            0x08, 0x7f => {
                index += 1;
                removeLastScalar(output[0..output_len], &output_len);
            },
            0x15 => {
                index += 1;
                output_len = 0;
            },
            0x17 => {
                index += 1;
                removeLastWord(output[0..output_len], &output_len);
            },
            else => {
                if (byte < 0x20) {
                    index += 1;
                    continue;
                }
                if (byte <= 0x7e) {
                    index += 1;
                    if (byte == ' ')
                        try appendSpace(output, &output_len)
                    else
                        try appendBytes(output, &output_len, &.{byte});
                    continue;
                }
                const sequence_len = std.unicode.utf8ByteSequenceLength(byte) catch
                    return error.InvalidUtf8;
                if (sequence_len > raw.len - index or
                    !std.unicode.utf8ValidateSlice(raw[index .. index + sequence_len]))
                    return error.InvalidUtf8;
                try appendBytes(output, &output_len, raw[index .. index + sequence_len]);
                index += sequence_len;
            },
        }
    }
    while (output_len != 0 and output[output_len - 1] == ' ') output_len -= 1;
    if (output_len == 0) return error.EmptyQuery;
    return output[0..output_len];
}

/// Accepts exactly one non-empty display line from a generator. Surrounding
/// whitespace and matching ASCII quotes are removed; controls and extra lines
/// are rejected rather than silently changing their meaning.
pub fn normalizeTitle(raw: []const u8, output: *[schema.max_agent_session_title_bytes]u8) ![]const u8 {
    var trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len >= 2 and
        ((trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') or
            (trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\'')))
        trimmed = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t");
    if (trimmed.len == 0 or trimmed.len > output.len) return error.InvalidTitleLength;
    if (!std.unicode.utf8ValidateSlice(trimmed)) return error.InvalidUtf8;
    for (trimmed) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidTitleControl;
    @memcpy(output[0..trimmed.len], trimmed);
    return output[0..trimmed.len];
}

fn skipEscape(bytes: []const u8, start: usize) usize {
    if (start + 1 >= bytes.len) return bytes.len;
    if (bytes[start + 1] != '[') return start + 2;
    var index = start + 2;
    while (index < bytes.len) : (index += 1) {
        if (bytes[index] >= 0x40 and bytes[index] <= 0x7e) return index + 1;
    }
    return bytes.len;
}

fn appendSpace(output: *[max_query_bytes]u8, output_len: *usize) !void {
    if (output_len.* == 0 or output[output_len.* - 1] == ' ') return;
    if (output_len.* == output.len) return error.QueryTooLong;
    output[output_len.*] = ' ';
    output_len.* += 1;
}

fn appendBytes(output: *[max_query_bytes]u8, output_len: *usize, bytes: []const u8) !void {
    if (bytes.len > output.len - output_len.*) return error.QueryTooLong;
    @memcpy(output[output_len.*..][0..bytes.len], bytes);
    output_len.* += bytes.len;
}

fn removeLastScalar(bytes: []const u8, len: *usize) void {
    if (len.* == 0) return;
    len.* -= 1;
    while (len.* != 0 and bytes[len.*] & 0xc0 == 0x80) len.* -= 1;
}

fn removeLastWord(bytes: []const u8, len: *usize) void {
    while (len.* != 0 and bytes[len.* - 1] == ' ') len.* -= 1;
    while (len.* != 0 and bytes[len.* - 1] != ' ') removeLastScalar(bytes, len);
}

test "capture distinguishes pasted newlines, cancellation, and submit across chunks" {
    var capture: Capture = .{};
    try std.testing.expect(!capture.feed("discard\x03"));
    try std.testing.expectEqual(@as(usize, 0), capture.raw().len);
    try std.testing.expect(!capture.feed("rename \x1b[20"));
    try std.testing.expect(!capture.feed("0~one\ntwo\x1b[201"));
    try std.testing.expect(!capture.feed("~ sidebar"));
    try std.testing.expect(capture.feed("\rignored"));
    try std.testing.expect(!capture.feed("second\r"));

    var normalized: [max_query_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "rename one two sidebar",
        try normalizeQuery(capture.raw(), &normalized),
    );
}

test "query normalization applies editing controls and validates UTF-8" {
    var output: [max_query_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "hello Zig",
        try normalizeQuery("hello X\x08Zig\r", &output),
    );
    try std.testing.expectEqualStrings(
        "replacement",
        try normalizeQuery("secret\x15replacement\r", &output),
    );
    try std.testing.expectEqualStrings(
        "one three",
        try normalizeQuery("one two\x17three\r", &output),
    );
    try std.testing.expectError(error.InvalidUtf8, normalizeQuery("bad\xff\r", &output));
}

test "title normalization accepts one bounded display line" {
    var output: [schema.max_agent_session_title_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Improve agent sidebar",
        try normalizeTitle("  \"Improve agent sidebar\"\n", &output),
    );
    try std.testing.expectError(
        error.InvalidTitleControl,
        normalizeTitle("first\nsecond", &output),
    );
    const oversized = [_]u8{'x'} ** (schema.max_agent_session_title_bytes + 1);
    try std.testing.expectError(error.InvalidTitleLength, normalizeTitle(&oversized, &output));
}

test "description command succeeds, rejects invalid output, times out, and may be absent" {
    const job: Job = .{
        .pane = .{ .id = @enumFromInt(1), .generation = 2 },
        .session_id = .{3} ** 16,
        .provider = .codex,
        .query = undefined,
        .query_len = 0,
    };
    const success = generate(std.testing.io, std.testing.allocator, .{
        .command = .{
            .arguments = &.{ "/bin/sh", "-c", "printf 'Improve agent sidebar\\n'" },
            .timeout_ms = 1000,
        },
        .job = job,
    });
    try std.testing.expectEqual(ResultStatus.success, success.status);
    try std.testing.expectEqualStrings("Improve agent sidebar", success.titleSlice());

    const invalid = generate(std.testing.io, std.testing.allocator, .{
        .command = .{
            .arguments = &.{ "/bin/sh", "-c", "printf 'first\\nsecond\\n'" },
            .timeout_ms = 1000,
        },
        .job = job,
    });
    try std.testing.expectEqual(ResultStatus.invalid_output, invalid.status);

    const timed_out = generate(std.testing.io, std.testing.allocator, .{
        .command = .{
            .arguments = &.{ "/bin/sh", "-c", "sleep 1" },
            .timeout_ms = 20,
        },
        .job = job,
    });
    try std.testing.expectEqual(ResultStatus.timeout, timed_out.status);

    const unavailable = generate(std.testing.io, std.testing.allocator, .{
        .command = .{
            .arguments = &.{"/definitely/not/a/telar-command"},
            .timeout_ms = 1000,
        },
        .job = job,
    });
    try std.testing.expectEqual(ResultStatus.unavailable, unavailable.status);
}
