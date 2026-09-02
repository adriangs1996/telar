//! Prompt and reply shaping for command suggestions. The runtime asks the
//! engine for one shell command line given the focused pane's working
//! directory, the last visible screen rows and the user's request; the
//! reply is reduced to that one line before it reaches a client.
//!
//! Screen text is bounded so the whole prompt fits the engine's prompt
//! cap, and the user never sees more than one suggested line.

const std = @import("std");
const core = @import("telar-core");
const engine = @import("../../engine/root.zig");

const schema = core.schema;

/// Visible rows sent as context; the last rows hold the latest command and
/// its output.
pub const context_rows = 24;
/// Screen bytes kept after the row dump; older rows are dropped first.
pub const max_context_bytes = 4 * 1024;

const instructions =
    "You are a shell assistant inside a terminal multiplexer. Reply with exactly one shell " ++
    "command line that fulfils the request, and nothing else: no markdown, no code fences, " ++
    "no quotes around the command, no explanation. If one command cannot fulfil the request, " ++
    "reply with one line starting with '#' that says why.\n";

pub const Context = struct {
    cwd: []const u8,
    screen: []const u8,
    request: []const u8,
};

/// Writes the complete engine prompt into `buffer`. The screen is
/// truncated from the front so the newest rows survive; the request is
/// always included whole because the wire bound keeps it small.
///
/// ```zig
/// var buffer: [engine.max_prompt_bytes]u8 = undefined;
/// const prompt = buildPrompt(.{ .cwd = cwd, .screen = screen, .request = text }, &buffer);
/// ```
pub fn buildPrompt(context: Context, buffer: *[engine.max_prompt_bytes]u8) []const u8 {
    const request = context.request[0..@min(context.request.len, schema.max_suggestion_request_bytes)];
    const cwd = context.cwd[0..@min(context.cwd.len, schema.max_cwd_bytes)];
    const fixed = instructions.len + "Working directory: ".len + cwd.len + "\nLast screen rows:\n".len +
        "\nRequest: ".len + request.len + 1;
    std.debug.assert(fixed < buffer.len);
    const screen_budget = @min(max_context_bytes, buffer.len - fixed);
    const screen = tailOnRowBoundary(context.screen, screen_budget);

    var writer: std.Io.Writer = .fixed(buffer);
    writer.print("{s}Working directory: {s}\nLast screen rows:\n{s}\nRequest: {s}\n", .{
        instructions,
        cwd,
        screen,
        request,
    }) catch unreachable;
    return writer.buffered();
}

/// Reduces an engine reply to one command line: the first non-empty line,
/// stripped of a surrounding code fence or backticks, bounded by the wire
/// cap. Returns null when nothing usable remains.
///
/// ```zig
/// const command = extractCommand(reply) orelse return .failed;
/// ```
pub fn extractCommand(reply: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, reply, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "```")) {
            continue;
        }

        if (line.len >= 2 and line[0] == '`' and line[line.len - 1] == '`') {
            line = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
        }

        if (line.len == 0) {
            continue;
        }

        if (line.len > schema.max_suggestion_bytes) {
            return null;
        }

        for (line) |byte| {
            if (byte < 0x20) return null;
        }

        return line;
    }

    return null;
}

fn tailOnRowBoundary(screen: []const u8, budget: usize) []const u8 {
    if (screen.len <= budget) {
        return screen;
    }

    const tail = screen[screen.len - budget ..];
    const newline = std.mem.indexOfScalar(u8, tail, '\n') orelse return tail;
    return tail[newline + 1 ..];
}

test "the prompt keeps the newest screen rows inside the engine cap" {
    var buffer: [engine.max_prompt_bytes]u8 = undefined;
    const prompt = buildPrompt(.{ .cwd = "/work/telar", .screen = "$ zig build\nerror: x\n", .request = "fix it" }, &buffer);
    try std.testing.expect(std.mem.endsWith(u8, prompt, "Last screen rows:\n$ zig build\nerror: x\n\nRequest: fix it\n"));
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Working directory: /work/telar\n") != null);

    const row = "0123456789" ** 20 ++ "\n";
    const long = row ** 40;
    const truncated = buildPrompt(.{ .cwd = "/", .screen = long, .request = "x" }, &buffer);
    try std.testing.expect(truncated.len <= engine.max_prompt_bytes);
    const rows = std.mem.indexOf(u8, truncated, "Last screen rows:\n").? + "Last screen rows:\n".len;
    try std.testing.expect(std.mem.startsWith(u8, truncated[rows..], "0123456789"));
    try std.testing.expect(std.mem.count(u8, truncated, "\n") < 40);
}

test "replies reduce to one command line" {
    try std.testing.expectEqualStrings("ls -lS", extractCommand("ls -lS\n").?);
    try std.testing.expectEqualStrings("ls -lS", extractCommand("\n  `ls -lS`  \nexplanation\n").?);
    try std.testing.expectEqualStrings("git status", extractCommand("```sh\ngit status\n```\n").?);
    try std.testing.expectEqualStrings("# cannot do that in one command", extractCommand("# cannot do that in one command").?);
    try std.testing.expect(extractCommand("\n\n") == null);
    try std.testing.expect(extractCommand("``") == null);
    try std.testing.expect(extractCommand("ls\x07") == null);
    try std.testing.expect(extractCommand("x" ** (schema.max_suggestion_bytes + 1)) == null);
}
