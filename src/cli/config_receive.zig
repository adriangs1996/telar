//! `telar machine receive-config`, the machine's half of the configuration
//! sync of `telar machine setup` (docs/flows/machine-setup.md). It reads a
//! bounded stream of files on standard input and writes each one under the
//! home, atomically and only when its bytes or mode differ. It writes only
//! under the agents' directories (`config_allowlist.acceptable`), never
//! through a symlink, and never a file the denylist names. It answers with
//! one line per file: `written`, `unchanged` or `refused PATH: why`.
//!
//! The stream, as `config_sync` writes it:
//!
//! ```text
//! telar-config 1
//! file 644 1234 .claude/settings.json
//! <1234 bytes>
//! end
//! ```
const std = @import("std");
const config_allowlist = @import("config_allowlist.zig");

pub const stream_header = "telar-config 1";
/// The most one file, all files and the file count may reach.
pub const max_file_bytes = 1024 * 1024;
pub const max_total_bytes = 16 * 1024 * 1024;
pub const max_files = 4096;
/// Modes a synced file may have: readable, or readable and executable.
pub const Mode = enum(u9) {
    regular = 0o644,
    executable = 0o755,
};

/// Reads the stream on standard input, writes the files under `$HOME` and
/// prints what happened to each; returns the exit status.
///
/// ```zig
/// std.process.exit(try config_receive.run(process_init));
/// ```
pub fn run(init: std.process.Init) !u8 {
    const home = std.process.Environ.getPosix(init.minimal.environ, "HOME") orelse return error.HomeUnavailable;
    var home_dir = try std.Io.Dir.openDirAbsolute(init.io, home, .{});
    defer home_dir.close(init.io);

    var input_buffer: [64 * 1024]u8 = undefined;
    var input = std.Io.File.stdin().readerStreaming(init.io, &input_buffer);
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    defer output.interface.flush() catch {};

    try receive(init.io, init.gpa, home_dir, &input.interface, &output.interface);
    return 0;
}

/// Takes every file of one stream from `reader` and writes the outcome of
/// each to `writer`. A malformed stream stops with an error after the files
/// before it were handled.
///
/// ```zig
/// try config_receive.receive(io, gpa, home, &reader, &writer);
/// ```
pub fn receive(io: std.Io, gpa: std.mem.Allocator, home: std.Io.Dir, reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
    if (!std.mem.eql(u8, try takeLine(reader), stream_header)) {
        return error.InvalidConfigStream;
    }

    const bytes = try gpa.alloc(u8, max_file_bytes);
    defer gpa.free(bytes);

    var files: usize = 0;
    var total: usize = 0;
    while (true) {
        const line = try takeLine(reader);
        if (std.mem.eql(u8, line, "end")) {
            return;
        }

        var words = std.mem.splitScalar(u8, line, ' ');
        const kind = words.next() orelse return error.InvalidConfigStream;
        const mode_text = words.next() orelse return error.InvalidConfigStream;
        const size_text = words.next() orelse return error.InvalidConfigStream;
        const path_text = words.rest();
        if (!std.mem.eql(u8, kind, "file")) {
            return error.InvalidConfigStream;
        }

        const size = std.fmt.parseInt(usize, size_text, 10) catch return error.InvalidConfigStream;
        files += 1;
        total += size;
        if (size > max_file_bytes or total > max_total_bytes or files > max_files) {
            return error.ConfigStreamTooLarge;
        }

        const mode = try parseMode(mode_text);
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        if (path_text.len > path_buffer.len) {
            return error.InvalidConfigStream;
        }

        // The reader's buffer is reused by the next read; keep the path.
        const path = path_buffer[0..path_text.len];
        @memcpy(path, path_text);
        reader.readSliceAll(bytes[0..size]) catch return error.InvalidConfigStream;
        const separator = reader.takeByte() catch return error.InvalidConfigStream;
        if (separator != '\n') {
            return error.InvalidConfigStream;
        }

        if (!config_allowlist.acceptable(path)) {
            try writer.print("refused {s}: not a path the sync may write\n", .{path});
            continue;
        }

        const outcome = place(io, home, path, bytes[0..size], mode) catch |err| {
            try writer.print("refused {s}: {s}\n", .{ path, @errorName(err) });
            continue;
        };

        try writer.print("{s} {s}\n", .{ @tagName(outcome), path });
    }
}

fn parseMode(text: []const u8) !Mode {
    if (std.mem.eql(u8, text, "755")) {
        return .executable;
    }

    if (std.mem.eql(u8, text, "644")) {
        return .regular;
    }

    return error.InvalidConfigStream;
}

// One line without its newline; a line the stream never ends is malformed.
fn takeLine(reader: *std.Io.Reader) ![]const u8 {
    const line = reader.takeDelimiterInclusive('\n') catch return error.InvalidConfigStream;
    return line[0 .. line.len - 1];
}

const Outcome = enum { written, unchanged };

// Writes `bytes` at `path` under `home` unless the file there already holds
// them with `mode`. Every directory on the way is opened without following
// symlinks, and a missing one is created owner-only.
fn place(io: std.Io, home: std.Io.Dir, path: []const u8, bytes: []const u8, mode: Mode) !Outcome {
    const parent_path = std.fs.path.dirname(path) orelse return error.InvalidConfigPath;
    const name = std.fs.path.basename(path);
    var parent = try openParent(io, home, parent_path);
    defer parent.close(io);

    if (parent.statFile(io, name, .{ .follow_symlinks = false })) |stat| {
        if (stat.kind != .file) {
            return error.NotARegularFile;
        }

        if (stat.size == bytes.len and stat.permissions.toMode() & 0o777 == @intFromEnum(mode) and try sameBytes(io, parent, name, bytes)) {
            return .unchanged;
        }
    } else |err| {
        if (err != error.FileNotFound) {
            return err;
        }
    }

    var nonce: [8]u8 = undefined;
    try io.randomSecure(&nonce);
    var temporary_buffer: [std.fs.max_name_bytes]u8 = undefined;
    const temporary = std.fmt.bufPrint(&temporary_buffer, ".telar-{s}", .{&std.fmt.bytesToHex(nonce, .lower)}) catch unreachable;
    var committed = false;
    defer if (!committed) {
        parent.deleteFile(io, temporary) catch {};
    };

    var file = try parent.createFile(io, temporary, .{
        .exclusive = true,
        .permissions = .fromMode(@intFromEnum(mode)),
    });
    var open = true;
    defer if (open) {
        file.close(io);
    };

    try file.writeStreamingAll(io, bytes);
    try file.setPermissions(io, .fromMode(@intFromEnum(mode)));
    try file.sync(io);
    file.close(io);
    open = false;

    try std.Io.Dir.rename(parent, temporary, parent, name, io);
    committed = true;
    return .written;
}

fn openParent(io: std.Io, home: std.Io.Dir, parent_path: []const u8) !std.Io.Dir {
    var current = try home.openDir(io, ".", .{ .follow_symlinks = false });
    errdefer current.close(io);

    var components = std.mem.splitScalar(u8, parent_path, '/');
    while (components.next()) |component| {
        const next = current.openDir(io, component, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => blk: {
                try current.createDir(io, component, .fromMode(0o700));
                break :blk try current.openDir(io, component, .{ .follow_symlinks = false });
            },
            error.SymLinkLoop, error.NotDir => return error.SymlinkOnTheWay,
            else => return err,
        };
        current.close(io);
        current = next;
    }

    return current;
}

fn sameBytes(io: std.Io, parent: std.Io.Dir, name: []const u8, bytes: []const u8) !bool {
    var file = try parent.openFile(io, name, .{ .follow_symlinks = false });
    defer file.close(io);

    var buffer: [16 * 1024]u8 = undefined;
    var reader = file.reader(io, &.{});
    var offset: usize = 0;
    while (true) {
        const read = reader.interface.readSliceShort(&buffer) catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
        };
        if (read == 0) {
            return offset == bytes.len;
        }

        if (offset + read > bytes.len or !std.mem.eql(u8, buffer[0..read], bytes[offset..][0..read])) {
            return false;
        }

        offset += read;
    }
}

fn testStream(buffer: []u8, files: []const [2][]const u8) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try writer.writeAll(stream_header ++ "\n");
    for (files) |file| {
        try writer.print("file 644 {d} {s}\n{s}\n", .{ file[1].len, file[0], file[1] });
    }

    try writer.writeAll("end\n");
    return writer.buffered();
}

test "files are written once, then reported unchanged" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var stream_buffer: [512]u8 = undefined;
    const stream = try testStream(&stream_buffer, &.{
        .{ ".claude/settings.json", "{\"model\":\"opus\"}" },
        .{ ".claude/skills/grill/SKILL.md", "# Grill\n" },
    });

    var answer_buffer: [512]u8 = undefined;
    var reader: std.Io.Reader = .fixed(stream);
    var answer: std.Io.Writer = .fixed(&answer_buffer);
    try receive(std.testing.io, std.testing.allocator, temp.dir, &reader, &answer);
    try std.testing.expectEqualStrings("written .claude/settings.json\nwritten .claude/skills/grill/SKILL.md\n", answer.buffered());

    var again: std.Io.Reader = .fixed(stream);
    answer = .fixed(&answer_buffer);
    try receive(std.testing.io, std.testing.allocator, temp.dir, &again, &answer);
    try std.testing.expectEqualStrings("unchanged .claude/settings.json\nunchanged .claude/skills/grill/SKILL.md\n", answer.buffered());

    var read_buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("# Grill\n", try temp.dir.readFile(std.testing.io, ".claude/skills/grill/SKILL.md", &read_buffer));
}

test "paths outside the agents' directories, credentials and symlinks are refused" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    try temp.dir.createDirPath(std.testing.io, "elsewhere");
    try temp.dir.symLink(std.testing.io, "elsewhere", ".codex", .{ .is_directory = true });
    try temp.dir.createDirPath(std.testing.io, ".claude");
    try temp.dir.symLink(std.testing.io, "../elsewhere/target", ".claude/CLAUDE.md", .{});

    var stream_buffer: [1024]u8 = undefined;
    const stream = try testStream(&stream_buffer, &.{
        .{ ".ssh/authorized_keys", "ssh-ed25519 AAAA" },
        .{ ".claude/../.ssh/authorized_keys", "ssh-ed25519 AAAA" },
        .{ ".codex/auth.json", "{}" },
        .{ ".codex/AGENTS.md", "through a symlinked directory" },
        .{ ".claude/CLAUDE.md", "through a symlinked file" },
    });

    var answer_buffer: [1024]u8 = undefined;
    var reader: std.Io.Reader = .fixed(stream);
    var answer: std.Io.Writer = .fixed(&answer_buffer);
    try receive(std.testing.io, std.testing.allocator, temp.dir, &reader, &answer);

    try std.testing.expectEqualStrings(
        "refused .ssh/authorized_keys: not a path the sync may write\n" ++
            "refused .claude/../.ssh/authorized_keys: not a path the sync may write\n" ++
            "refused .codex/auth.json: not a path the sync may write\n" ++
            "refused .codex/AGENTS.md: SymlinkOnTheWay\n" ++
            "refused .claude/CLAUDE.md: NotARegularFile\n",
        answer.buffered(),
    );
    try std.testing.expectError(error.FileNotFound, temp.dir.statFile(std.testing.io, "elsewhere/AGENTS.md", .{}));
    try std.testing.expectError(error.FileNotFound, temp.dir.statFile(std.testing.io, "elsewhere/target", .{}));
}

test "a stream past its bounds or out of shape stops" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var answer_buffer: [256]u8 = undefined;
    for ([_][]const u8{
        "not a stream\n",
        stream_header ++ "\nfile 644 99999999 .claude/x\n",
        stream_header ++ "\nfile 600 1 .claude/x\nx\nend\n",
        stream_header ++ "\nfile 644 5 .claude/x\nab",
    }) |stream| {
        var reader: std.Io.Reader = .fixed(stream);
        var answer: std.Io.Writer = .fixed(&answer_buffer);
        if (receive(std.testing.io, std.testing.allocator, temp.dir, &reader, &answer)) |_| {
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}
