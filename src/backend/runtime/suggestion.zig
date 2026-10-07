//! Prompt and reply shaping for command suggestions. The runtime asks the
//! engine for one shell command line given the focused pane's working
//! directory, the last visible screen rows and the user's request; the
//! reply is reduced to that one line before it reaches a client.
//!
//! Screen text is bounded so the whole prompt fits the engine's prompt
//! cap, and the user never sees more than one suggested line.

const core = @import("telar-core");
const pi_rpc = @import("pi_rpc");
const types = pi_rpc.types;
const std = @import("std");

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

/// Writes the complete engine prompt into `buffer`. The screen is
/// truncated from the front so the newest rows survive; the request is
/// always included whole because the wire bound keeps it small.
///
/// ```zig
/// var buffer: [engine.max_prompt_bytes]u8 = undefined;
/// const prompt = buildPrompt(cwd, screen, text, &buffer);
/// ```
pub fn buildPrompt(cwd_text: []const u8, screen_text: []const u8, request_text: []const u8, buffer: *[types.max_prompt_bytes]u8) []const u8 {
    const request = request_text[0..@min(request_text.len, core.max_suggestion_request_bytes)];
    const cwd = cwd_text[0..@min(cwd_text.len, core.max_cwd_bytes)];
    const fixed = instructions.len + "Working directory: ".len + cwd.len + "\nLast screen rows:\n".len +
        "\nRequest: ".len + request.len + 1;
    std.debug.assert(fixed < buffer.len);
    const screen_budget = @min(max_context_bytes, buffer.len - fixed);
    const screen = tailOnRowBoundary(screen_text, screen_budget);

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

        if (line.len > core.max_suggestion_bytes) {
            return null;
        }

        for (line) |byte| {
            if (byte < 0x20) {
                return null;
            }
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
