//! Child `t=f` transmissions the pane reads itself. The emulator's own file
//! medium stays disabled; a complete transmit (`a=t` or `a=T`, unchunked)
//! naming a file the pane accepts is replayed to it as the chunked direct
//! upload the protocol already defines, so PNG decoding, quotas, display and
//! replies stay the emulator's. Programs such as snacks.nvim send every
//! local image this way. Nothing allocates: the file streams through one
//! stack chunk at a time.
const std = @import("std");
const kitty_protocol = @import("kitty_protocol");
const vtscan = @import("vtscan");
const shared_transfer = @import("shared_transfer.zig");
const ControlFields = kitty_protocol.ControlFields;

/// Longer control data is left to the emulator, which refuses the medium.
pub const max_control_bytes = 512;
const introducer = "\x1b_G";
const terminator = "\x1b\\";
const final_chunk = "\x1b_Gm=0;\x1b\\";
/// The protocol's recommended chunk: 4096 base64 bytes.
const raw_chunk_bytes = 3072;
const encoded_chunk_bytes = std.base64.standard.Encoder.calcSize(raw_chunk_bytes);
const chunk_bytes = introducer.len + max_control_bytes + ",t=d,m=1;".len + encoded_chunk_bytes + terminator.len;

/// The next complete `t=f` transmission in `bytes` at or after `from`.
///
/// ```zig
/// while (file_transmission.find(bytes, search_from)) |found| search_from = found.end;
/// ```
pub fn find(bytes: []const u8, from: usize) ?FileTransmission {
    var search_from = from;
    while (std.mem.indexOfPos(u8, bytes, search_from, introducer)) |start| {
        const end = std.mem.indexOfPos(u8, bytes, start + introducer.len, terminator) orelse return null;
        search_from = end + terminator.len;
        const command = bytes[start + introducer.len .. end];
        const separator = std.mem.indexOfScalar(u8, command, ';') orelse continue;
        if (separator > max_control_bytes or separator + 1 == command.len or !framedWhole(command)) {
            continue;
        }

        const range = parseControl(command[0..separator]) orelse continue;
        return .{
            .start = start,
            .end = end + terminator.len,
            .control = command[0..separator],
            .encoded_path = command[separator + 1 ..],
            .offset = range.offset,
            .size = range.size,
        };
    }

    return null;
}

/// Replays `found` to `sink` (`observe([]const u8)`) as a chunked direct
/// upload of at most `limit` bytes. False, with nothing written, when the
/// pane refuses the file; the caller then lets the emulator refuse the
/// command as it is. A file that shrinks mid-read ends the upload early and
/// the emulator rejects what arrived.
///
/// ```zig
/// if (!file_transmission.forward(found, limit, &sink)) sink.observe(bytes[found.start..found.end]);
/// ```
pub fn forward(found: FileTransmission, limit: u64, sink: anytype) bool {
    const file = shared_transfer.openChildRegular(found.encoded_path) orelse return false;
    defer file.close();

    if (found.offset > file.size) {
        return false;
    }

    const available = file.size - found.offset;
    const length = found.size orelse available;
    if (length == 0 or length > available or length > limit) {
        return false;
    }

    var raw: [raw_chunk_bytes]u8 = undefined;
    var chunk: [chunk_bytes]u8 = undefined;
    var sent: u64 = 0;
    while (sent < length) {
        const take: usize = @intCast(@min(raw_chunk_bytes, length - sent));
        if (!readAt(file.fd, raw[0..take], found.offset + sent)) {
            if (sent == 0) {
                return false;
            }

            sink.observe(final_chunk);
            return true;
        }

        const first = sent == 0;
        sent += take;
        sink.observe(encodeChunk(.{
            .buffer = &chunk,
            .control = if (first) found.control else null,
            .raw = raw[0..take],
            .more = sent < length,
        }));
    }

    return true;
}

// One chunk: the first carries the child's control data less its file
// keys, the rest only whether more follow.
fn encodeChunk(request: ChunkRequest) []const u8 {
    var writer = std.Io.Writer.fixed(request.buffer);
    // SAFETY: `chunk_bytes` holds the introducer, `max_control_bytes` of
    // control, the longest added keys, one encoded chunk and the terminator.
    writeChunk(&writer, request) catch unreachable;
    return writer.buffered();
}

fn writeChunk(writer: *std.Io.Writer, request: ChunkRequest) std.Io.Writer.Error!void {
    try writer.writeAll(introducer);
    if (request.control) |control| {
        var fields = ControlFields.init(control);
        // SAFETY: `find` accepted this control, so every field parses.
        while (fields.next() catch unreachable) |field| {
            switch (field.key) {
                't', 'S', 'O', 'm' => continue,
                else => {},
            }

            try writer.print("{c}={s},", .{ field.key, field.value });
        }

        try writer.writeAll("t=d,");
    }

    try writer.print("m={d};", .{@intFromBool(request.more)});
    const Encoder = std.base64.standard.Encoder;
    var encoded: [encoded_chunk_bytes]u8 = undefined;
    try writer.writeAll(Encoder.encode(encoded[0..Encoder.calcSize(request.raw.len)], request.raw));
    try writer.writeAll(terminator);
}

// Fills `buffer` from `offset`, or false when the file ends or fails first.
fn readAt(fd: std.c.fd_t, buffer: []u8, offset: u64) bool {
    var filled: usize = 0;
    while (filled < buffer.len) {
        const position = std.math.cast(std.c.off_t, offset + filled) orelse return false;
        const count = std.c.pread(fd, buffer[filled..].ptr, buffer.len - filled, position);
        if (count < 0) {
            if (std.posix.errno(count) == .INTR) {
                continue;
            }

            return false;
        }

        if (count == 0) {
            return false;
        }

        filled += @intCast(count);
    }

    return true;
}

// The command is one APC string as Ghostty frames it: no byte inside it
// would have ended the string before this terminator.
fn framedWhole(command: []const u8) bool {
    for (command) |byte| {
        if (!vtscan.ApcFraming.isContent(byte)) {
            return false;
        }
    }

    return true;
}

// Accepts an unchunked transmit from a file: `a` absent, `t` or `T`; `t=f`;
// `m` absent or zero. `S` and `O` select the bytes to read.
fn parseControl(control: []const u8) ?Range {
    var file = false;
    var range: Range = .{};
    var fields = ControlFields.init(control);
    while (fields.next() catch return null) |field| {
        const value = field.value;
        switch (field.key) {
            'a' => {
                if (!std.mem.eql(u8, value, "t") and !std.mem.eql(u8, value, "T")) {
                    return null;
                }
            },
            't' => {
                if (!std.mem.eql(u8, value, "f")) {
                    return null;
                }

                file = true;
            },
            'm' => {
                if (!std.mem.eql(u8, value, "0")) {
                    return null;
                }
            },
            'S' => range.size = std.fmt.parseUnsigned(u64, value, 10) catch return null,
            'O' => range.offset = std.fmt.parseUnsigned(u64, value, 10) catch return null,
            else => {},
        }
    }

    return if (file) range else null;
}

const FileTransmission = struct {
    /// The command's bytes in the scanned output, introducer to terminator.
    start: usize,
    end: usize,
    control: []const u8,
    encoded_path: []const u8,
    offset: u64,
    /// Bytes to read from `offset`; null reads to the end of the file.
    size: ?u64,
};

const Range = struct {
    offset: u64 = 0,
    size: ?u64 = null,
};

const ChunkRequest = struct {
    buffer: *[chunk_bytes]u8,
    /// The child's control data on the first chunk, null on the rest.
    control: ?[]const u8,
    raw: []const u8,
    more: bool,
};
