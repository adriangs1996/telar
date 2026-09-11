const history = @import("arguments/history.zig");
const max_import_command_bytes_module = @import("telar-core").max_import_command_bytes;
const ImportedEntry = @import("ImportedEntry.zig");
const std = @import("std");
/// Line-driven histfile parser producing (timestamp, command) entries.
/// zsh extended history joins backslash continuations; plain lines fall back
/// to a zero timestamp the runtime stores as-is.
const ImportParser = @This();

kind: history.HistoryImportKind,
pending_time_ms: i64 = 0,
/// Two alternating buffers: `flush` returns a slice into the active one
/// and `begin` switches to the other, so a finished entry stays valid
/// while the next command starts on the same fed line.
command_storage: [2][max_import_command_bytes_module]u8 = undefined,
active: u1 = 0,
command_len: usize = 0,
command_active: bool = false,

pub fn feed(state: *ImportParser, raw_line: []const u8) ?ImportedEntry {
    const line = std.mem.trimEnd(u8, raw_line, "\r");
    return switch (state.kind) {
        .auto => unreachable,
        .zsh => state.feedZsh(line),
        .bash => state.feedBash(line),
        .fish => state.feedFish(line),
    };
}

pub fn flush(state: *ImportParser) ?ImportedEntry {
    if (!state.command_active or state.command_len == 0) {
        return null;
    }

    state.command_active = false;
    return .{ .started_at_ms = state.pending_time_ms, .command = state.command_storage[state.active][0..state.command_len] };
}

fn feedZsh(state: *ImportParser, line: []const u8) ?ImportedEntry {
    if (state.command_active) {
        if (state.command_len != 0 and state.command_storage[state.active][state.command_len - 1] == '\\') {
            state.command_len -= 1;
            state.append("\n");
            state.append(line);
            if (line.len != 0 and line[line.len - 1] == '\\') {
                return null;
            }

            return state.flush();
        }
    }

    const finished = state.flush();
    if (std.mem.startsWith(u8, line, ": ")) {
        const semicolon = std.mem.indexOfScalar(u8, line, ';') orelse return finished;
        const meta = line[2..semicolon];
        const colon = std.mem.indexOfScalar(u8, meta, ':') orelse return finished;
        const seconds = std.fmt.parseInt(i64, meta[0..colon], 10) catch 0;
        state.begin(seconds * 1_000, line[semicolon + 1 ..]);
        if (line.len != 0 and line[line.len - 1] == '\\') {
            return finished;
        }
    } else if (line.len != 0) {
        state.begin(0, line);
    } else {
        return finished;
    }

    if (state.command_len != 0 and state.command_storage[state.active][state.command_len - 1] == '\\') {
        return finished;
    }
    if (finished) |value| {
        // Two complete commands cannot finish on one line; the previous
        // one is returned and the current one waits for the next feed.
        return value;
    }

    return state.flush();
}

fn feedBash(state: *ImportParser, line: []const u8) ?ImportedEntry {
    if (line.len > 1 and line[0] == '#') {
        const seconds = std.fmt.parseInt(i64, line[1..], 10) catch return state.emitPlain(line);
        const finished = state.flush();
        state.pending_time_ms = seconds * 1_000;
        return finished;
    }

    return state.emitPlain(line);
}

fn emitPlain(state: *ImportParser, line: []const u8) ?ImportedEntry {
    if (line.len == 0) {
        return null;
    }

    const finished = state.flush();
    const time = state.pending_time_ms;
    state.begin(time, line);
    if (finished) |value| {
        return value;
    }

    return state.flush();
}

fn feedFish(state: *ImportParser, line: []const u8) ?ImportedEntry {
    if (std.mem.startsWith(u8, line, "- cmd: ")) {
        const finished = state.flush();
        state.begin(0, line["- cmd: ".len..]);
        state.command_active = true;
        if (finished) |value| {
            return value;
        }

        return null;
    }
    if (std.mem.startsWith(u8, line, "  when: ")) {
        const seconds = std.fmt.parseInt(i64, line["  when: ".len..], 10) catch 0;
        state.pending_time_ms = seconds * 1_000;
        return state.flush();
    }

    return null;
}

fn begin(state: *ImportParser, time_ms: i64, command: []const u8) void {
    state.active ^= 1;
    state.pending_time_ms = time_ms;
    state.command_len = 0;
    state.command_active = true;
    state.append(command);
}

fn append(state: *ImportParser, bytes: []const u8) void {
    const buffer = &state.command_storage[state.active];
    const room = buffer.len - state.command_len;
    const take = @min(room, bytes.len);
    @memcpy(buffer[state.command_len .. state.command_len + take], bytes[0..take]);
    state.command_len += take;
}
