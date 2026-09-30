const core = @import("telar-core");
const history = @import("arguments/history.zig");
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
command_storage: [2][core.max_import_command_bytes]u8 = undefined,
active: u1 = 0,
/// Bytes of the active command kept in its buffer.
command_len: usize = 0,
/// Bytes of the active command as the file has it; past the buffer the
/// command is skipped whole, never cut.
command_bytes: usize = 0,
/// The command's last byte, which decides a zsh continuation even when the
/// buffer no longer holds it.
last_byte: u8 = 0,
command_active: bool = false,
/// Commands skipped because they passed `core.max_import_command_bytes`.
skipped: usize = 0,
/// Bytes of the longest skipped command.
largest_skipped: usize = 0,

pub fn feed(self: *ImportParser, raw_line: []const u8) ?ImportedEntry {
    const line = std.mem.trimEnd(u8, raw_line, "\r");
    return switch (self.kind) {
        .auto => unreachable,
        .zsh => self.feedZsh(line),
        .bash => self.feedBash(line),
        .fish => self.feedFish(line),
    };
}

/// Ends the active command. One longer than the import limit is counted
/// in `skipped` instead of returned.
///
/// ```zig
/// if (parser.flush()) |entry| try sender.push(entry);
/// ```
pub fn flush(self: *ImportParser) ?ImportedEntry {
    if (!self.command_active or self.command_bytes == 0) {
        return null;
    }

    self.command_active = false;
    if (self.command_bytes > self.command_len) {
        self.skipped += 1;
        self.largest_skipped = @max(self.largest_skipped, self.command_bytes);
        return null;
    }

    return .{ .started_at_ms = self.pending_time_ms, .command = self.command_storage[self.active][0..self.command_len] };
}

fn feedZsh(self: *ImportParser, line: []const u8) ?ImportedEntry {
    if (self.command_active) {
        if (self.continues()) {
            self.dropLastByte();
            self.append("\n");
            self.append(line);
            if (line.len != 0 and line[line.len - 1] == '\\') {
                return null;
            }

            return self.flush();
        }
    }

    const finished = self.flush();
    if (std.mem.startsWith(u8, line, ": ")) {
        const semicolon = std.mem.indexOfScalar(u8, line, ';') orelse return finished;
        const meta = line[2..semicolon];
        const colon = std.mem.indexOfScalar(u8, meta, ':') orelse return finished;
        const seconds = std.fmt.parseInt(i64, meta[0..colon], 10) catch 0;
        self.begin(seconds * 1_000, line[semicolon + 1 ..]);
        if (line.len != 0 and line[line.len - 1] == '\\') {
            return finished;
        }
    } else if (line.len != 0) {
        self.begin(0, line);
    } else {
        return finished;
    }

    if (self.continues()) {
        return finished;
    }
    if (finished) |value| {
        // Two complete commands cannot finish on one line; the previous
        // one is returned and the current one waits for the next feed.
        return value;
    }

    return self.flush();
}

fn feedBash(self: *ImportParser, line: []const u8) ?ImportedEntry {
    if (line.len > 1 and line[0] == '#') {
        const seconds = std.fmt.parseInt(i64, line[1..], 10) catch return self.emitPlain(line);
        const finished = self.flush();
        self.pending_time_ms = seconds * 1_000;
        return finished;
    }

    return self.emitPlain(line);
}

fn emitPlain(self: *ImportParser, line: []const u8) ?ImportedEntry {
    if (line.len == 0) {
        return null;
    }

    const finished = self.flush();
    const time = self.pending_time_ms;
    self.begin(time, line);
    if (finished) |value| {
        return value;
    }

    return self.flush();
}

fn feedFish(self: *ImportParser, line: []const u8) ?ImportedEntry {
    if (std.mem.startsWith(u8, line, "- cmd: ")) {
        const finished = self.flush();
        self.begin(0, line["- cmd: ".len..]);
        self.command_active = true;
        if (finished) |value| {
            return value;
        }

        return null;
    }
    if (std.mem.startsWith(u8, line, "  when: ")) {
        const seconds = std.fmt.parseInt(i64, line["  when: ".len..], 10) catch 0;
        self.pending_time_ms = seconds * 1_000;
        return self.flush();
    }

    return null;
}

fn begin(self: *ImportParser, time_ms: i64, command: []const u8) void {
    self.active ^= 1;
    self.pending_time_ms = time_ms;
    self.command_len = 0;
    self.command_bytes = 0;
    self.last_byte = 0;
    self.command_active = true;
    self.append(command);
}

/// Adds bytes to the active command. What does not fit is only counted, so
/// `flush` skips the whole command.
fn append(self: *ImportParser, bytes: []const u8) void {
    if (bytes.len == 0) {
        return;
    }

    self.command_bytes += bytes.len;
    self.last_byte = bytes[bytes.len - 1];
    if (self.command_bytes > self.command_storage[self.active].len) {
        return;
    }

    @memcpy(self.command_storage[self.active][self.command_len..][0..bytes.len], bytes);
    self.command_len += bytes.len;
}

/// Whether the active zsh command ends in a backslash that joins the next line.
fn continues(self: *const ImportParser) bool {
    return self.command_bytes != 0 and self.last_byte == '\\';
}

/// Removes the continuation backslash before the joined line is added.
fn dropLastByte(self: *ImportParser) void {
    self.command_bytes -= 1;
    if (self.command_bytes < self.command_len) {
        self.command_len = self.command_bytes;
    }

    self.last_byte = 0;
}
