//! The chat name Cursor Agent keeps in `meta.json`. `/rename` and the names
//! Cursor generates fire no hook: they only rewrite the `title` of the chat's
//! metadata, at `<config>/chats/<md5 of the launch directory>/<chat>/meta.json`.
//! `locate` finds that file for a hook, which knows the chat but not the
//! directory the agent was launched from; `chatTitle` reads the name.

const std = @import("std");
const utf8 = @import("utf8.zig");

/// A `meta.json` is a few hundred bytes; a larger file is not one.
pub const max_meta_bytes = 16 * 1024;
/// Launch directories `locate` visits before it gives up on a chat.
pub const max_scanned_directories = 4096;
/// Chat ids are 36-byte UUIDs; this leaves room without trusting the input.
const max_chat_bytes = 64;
/// Scratch for the few fields of one metadata object.
const max_parse_bytes = 4 * 1024;
const meta_file = "meta.json";
const Md5 = std.crypto.hash.Md5;
const md5_hex_bytes = 2 * Md5.digest_length;

/// Cursor's configuration directory: `CURSOR_CONFIG_DIR`, else
/// `$XDG_CONFIG_HOME/cursor`, else `~/.cursor`, the order Cursor resolves it.
///
/// ```zig
/// const root = cursor.configDirectory(env("CURSOR_CONFIG_DIR"), env("XDG_CONFIG_HOME"), env("HOME"), &buffer) orelse return;
/// ```
pub fn configDirectory(config_dir: ?[]const u8, xdg_config_home: ?[]const u8, home_dir: ?[]const u8, buffer: []u8) ?[]const u8 {
    if (nonEmpty(config_dir)) |directory| {
        return std.fmt.bufPrint(buffer, "{s}", .{directory}) catch null;
    }

    if (nonEmpty(xdg_config_home)) |directory| {
        return std.fmt.bufPrint(buffer, "{s}/cursor", .{directory}) catch null;
    }

    const home = nonEmpty(home_dir) orelse return null;
    return std.fmt.bufPrint(buffer, "{s}/.cursor", .{home}) catch null;
}

/// Finds the metadata of `chat` under the configuration directory `root`;
/// `workspace` is the first workspace root the hook reports, maybe empty.
/// Cursor hashes the directory it was launched from, which is the
/// workspace root unless the agent started in a subdirectory, so the
/// workspace is tried first and the other launch directories after it, at
/// most `max_scanned_directories`. Only a regular file counts. The path
/// borrows `buffer`.
///
/// ```zig
/// const meta = cursor.locate(io, root, roots[0], id, &buffer) orelse return;
/// ```
pub fn locate(io: std.Io, root: []const u8, workspace: []const u8, chat: []const u8, buffer: []u8) ?[]const u8 {
    if (!validChat(chat)) {
        return null;
    }

    if (workspace.len != 0) {
        const digest = directoryDigest(workspace);
        const path = metaPath(buffer, root, &digest, chat) orelse return null;
        if (isRegularFile(io, path)) {
            return path;
        }
    }

    var chats_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const chats = std.fmt.bufPrint(&chats_buffer, "{s}/chats", .{root}) catch return null;
    var directory = std.Io.Dir.cwd().openDir(io, chats, .{ .iterate = true }) catch return null;
    defer directory.close(io);
    var iterator = directory.iterate();
    var scanned: usize = 0;

    while (iterator.next(io) catch null) |entry| {
        if (scanned == max_scanned_directories) {
            return null;
        }

        scanned += 1;
        if (entry.kind != .directory or entry.name.len != md5_hex_bytes) {
            continue;
        }

        const path = metaPath(buffer, root, entry.name, chat) orelse continue;
        if (isRegularFile(io, path)) {
            return path;
        }
    }

    return null;
}

/// Reads the chat's current name from the `meta.json` at `path`. The file
/// must sit in the directory of `chat`, so a path reported for another chat
/// never renames this one. A missing or oversized file, or one that is not
/// JSON yet, reports nothing; metadata without a title reports an empty
/// one. The title borrows `title_buffer`, cut on a UTF-8 boundary.
///
/// ```zig
/// const title = cursor.chatTitle(io, watch.pathSlice(), watch.session.slice(), &title_buffer) orelse return;
/// ```
pub fn chatTitle(io: std.Io, path: []const u8, chat: []const u8, title_buffer: []u8) ?[]const u8 {
    if (!belongsTo(path, chat)) {
        return null;
    }

    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    var bytes: [max_meta_bytes]u8 = undefined;
    var reader = file.reader(io, &.{});
    const len = reader.interface.readSliceShort(&bytes) catch return null;
    if (len == bytes.len) {
        return null;
    }

    return scan(bytes[0..len], title_buffer);
}

/// Extracts `title` from metadata bytes; absent reads as empty.
///
/// ```zig
/// const title = cursor.scan("{\"title\":\"Fix proxy\"}", &buffer).?;
/// ```
pub fn scan(bytes: []const u8, title_buffer: []u8) ?[]const u8 {
    var parse_buffer: [max_parse_bytes]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&parse_buffer);
    const parsed = std.json.parseFromSliceLeaky(Meta, fixed.allocator(), bytes, .{ .ignore_unknown_fields = true }) catch return null;
    return utf8.truncate(title_buffer, parsed.title);
}

const Meta = struct {
    title: []const u8 = "",
};

fn metaPath(buffer: []u8, root: []const u8, digest: []const u8, chat: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buffer, "{s}/chats/{s}/{s}/" ++ meta_file, .{ root, digest, chat }) catch null;
}

fn directoryDigest(directory: []const u8) [md5_hex_bytes]u8 {
    var digest: [Md5.digest_length]u8 = undefined;
    Md5.hash(directory, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn isRegularFile(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return stat.kind == .file;
}

// Chat ids are UUIDs; anything else could step out of the chats directory.
fn validChat(chat: []const u8) bool {
    if (chat.len == 0 or chat.len > max_chat_bytes) {
        return false;
    }

    for (chat) |byte| {
        if (!std.ascii.isHex(byte) and byte != '-') {
            return false;
        }
    }

    return true;
}

fn belongsTo(path: []const u8, chat: []const u8) bool {
    if (!validChat(chat) or !std.mem.eql(u8, std.fs.path.basename(path), meta_file)) {
        return false;
    }

    const directory = std.fs.path.dirname(path) orelse return false;
    return std.mem.eql(u8, std.fs.path.basename(directory), chat);
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const text = value orelse return null;
    return if (text.len == 0) null else text;
}

const test_chat = "7f8ca51a-88f1-40a0-a73f-0f180d035134";

test "the configuration directory follows Cursor's precedence" {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("/cfg", configDirectory("/cfg", "/xdg", "/home/me", &buffer).?);
    try std.testing.expectEqualStrings("/xdg/cursor", configDirectory("", "/xdg", "/home/me", &buffer).?);
    try std.testing.expectEqualStrings("/home/me/.cursor", configDirectory(null, null, "/home/me", &buffer).?);
    try std.testing.expect(configDirectory(null, null, null, &buffer) == null);
}

test "the launch directory digest matches Cursor's chat directory" {
    // Observed: a chat started in this directory lived under this digest.
    const digest = directoryDigest("/private/tmp/claude-501/-Users-adriangonzalez-sandbox-telar/3795fba6-00c7-4090-84a1-bb4592db7ad4/scratchpad/cursor/proj");
    try std.testing.expectEqualStrings("8ab1766528a4f5793554c6ceee08b55b", &digest);
}

test "locate prefers the workspace digest and finds a chat started in a subdirectory" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try temp.dir.realPath(io, &root_buffer)];

    const workspace_digest = directoryDigest("/work/project");
    var relative_buffer: [256]u8 = undefined;
    const in_workspace = try std.fmt.bufPrint(&relative_buffer, "chats/{s}/{s}", .{ &workspace_digest, test_chat });
    try temp.dir.createDirPath(io, in_workspace);
    try temp.dir.writeFile(io, .{
        .sub_path = try std.fmt.bufPrint(&relative_buffer, "chats/{s}/{s}/meta.json", .{ &workspace_digest, test_chat }),
        .data = "{}",
    });

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const found = locate(io, root, "/work/project", test_chat, &buffer).?;
    try std.testing.expect(std.mem.endsWith(u8, found, &workspace_digest ++ "/" ++ test_chat ++ "/meta.json"));

    const other = "0192aaaa-bbbb-cccc-dddd-eeeeffff0000";
    try temp.dir.createDirPath(io, "chats/76b746cf6ee7db65af4a3fdacb2aa1a3/" ++ other);
    try temp.dir.writeFile(io, .{
        .sub_path = "chats/76b746cf6ee7db65af4a3fdacb2aa1a3/" ++ other ++ "/meta.json",
        .data = "{}",
    });
    const scanned = locate(io, root, "/work/project", other, &buffer).?;
    try std.testing.expect(std.mem.endsWith(u8, scanned, "76b746cf6ee7db65af4a3fdacb2aa1a3/" ++ other ++ "/meta.json"));

    try std.testing.expect(locate(io, root, "", "../../etc", &buffer) == null);
    try std.testing.expect(locate(io, root, "", "0192aaaa-bbbb-cccc-dddd-000000000000", &buffer) == null);
}

test "chat titles come from the chat's own metadata" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDirPath(io, test_chat);
    try temp.dir.writeFile(io, .{
        .sub_path = test_chat ++ "/meta.json",
        .data = "{\"schemaVersion\":1,\"createdAtMs\":1790420699397,\"hasConversation\":true,\"title\":\"Telar probe name\",\"cwd\":\"/work\"}",
    });
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = directory_buffer[0..try temp.dir.realPath(io, &directory_buffer)];
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}/meta.json", .{ directory, test_chat });
    var title: [96]u8 = undefined;

    try std.testing.expectEqualStrings("Telar probe name", chatTitle(io, path, test_chat, &title).?);
    try std.testing.expect(chatTitle(io, path, "0192aaaa-bbbb-cccc-dddd-eeeeffff0000", &title) == null);
    try std.testing.expect(chatTitle(io, path[0 .. path.len - 1], test_chat, &title) == null);
}

test "scan reads an absent title as empty, rejects partial JSON and bounds long names" {
    var buffer: [96]u8 = undefined;
    try std.testing.expectEqualStrings("", scan("{\"schemaVersion\":1,\"hasConversation\":false}", &buffer).?);
    try std.testing.expect(scan("{\"title\":\"Fix", &buffer) == null);
    const long = scan("{\"title\":\"" ++ ("é" ** 60) ++ "\"}", &buffer).?;
    try std.testing.expectEqual(@as(usize, 96), long.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(long));
}
