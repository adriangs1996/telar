//! The listener port each runtime bound last time, kept in the proxy
//! directory as `proxy-port-<endpoint key>`, so a process that inherited
//! `HTTPS_PROXY` keeps its destination across its runtime's restarts even
//! when other runtimes share the directory. Earlier versions kept one shared
//! `proxy-port`; a runtime without its own file prefers that port and
//! retires the shared file once it binds it. Losing a file only costs that
//! stability.

const localca = @import("localca");
const std = @import("std");
const listener_support = @import("listener_support.zig");
const Paths = @import("Paths.zig");
const PortMemory = @This();

const ca = localca.ca;
const PortSet = listener_support.PortSet;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// Name prefix of every runtime's port file.
pub const file_prefix = "proxy-port-";
/// Bytes of the endpoint digest a port file's name carries.
const key_bytes = 8;
const file_name_len = file_prefix.len + key_bytes * 2;
/// Most directory entries one scan looks at, so a crowded directory cannot
/// stall a start.
const max_scanned_entries = 4096;

/// The port this runtime bound last time.
own: ?u16 = null,
/// The port in the shared file of earlier versions.
legacy: ?u16 = null,
/// Ports that other runtimes sharing the directory remember.
reserved: PortSet = .initEmpty(),

const Scan = union(enum) {
    /// Collect every other runtime's port.
    reserve: *PortSet,
    /// Remove every other runtime's file that records this port.
    forget: u16,
};

/// Formats this runtime's port file path. The endpoint's digest keys it, so
/// one socket always finds the same file and another socket never does.
///
/// ```zig
/// const path = try PortMemory.path(&buffer, proxy_directory, endpoint);
/// ```
pub fn path(buffer: []u8, directory: []const u8, endpoint: []const u8) ![]const u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(endpoint, &digest, .{});
    const key = std.fmt.bytesToHex(digest[0..key_bytes].*, .lower);

    return std.fmt.bufPrint(buffer, "{s}/{s}{s}", .{ directory, file_prefix, &key });
}

/// Reads what the proxy directory remembers: this runtime's port, the
/// shared port of earlier versions, and the ports other runtimes keep. The
/// shared port counts as another runtime's once this one has its own.
///
/// ```zig
/// const memory = PortMemory.load(io, paths);
/// var listener = try Listener.bind(io, memory.preferred(), &memory.reserved);
/// ```
pub fn load(io: std.Io, paths: Paths) PortMemory {
    var memory: PortMemory = .{
        .own = recall(io, std.Io.Dir.cwd(), paths.port),
        .legacy = recall(io, std.Io.Dir.cwd(), paths.legacy_port),
    };

    scanOthers(io, paths.port, .{ .reserve = &memory.reserved });
    if (memory.own != null) {
        if (memory.legacy) |port| {
            memory.reserved.set(port - listener_support.first_port);
        }
    }

    return memory;
}

/// The port to try first: this runtime's own, else the shared port of
/// earlier versions.
///
/// ```zig
/// const preferred = memory.preferred();
/// ```
pub fn preferred(self: *const PortMemory) ?u16 {
    return self.own orelse self.legacy;
}

/// Records the bound port as this runtime's. Binding the shared port of
/// earlier versions without a file of its own migrates this runtime onto
/// it, so the shared file is retired. Binding a port another runtime
/// remembers means that runtime lost it, so its file is forgotten and the
/// directory keeps at most one file per port. Failure to write is not an
/// error: the proxy runs on the port it bound either way.
///
/// ```zig
/// memory.remember(io, paths, listener.port());
/// ```
pub fn remember(self: *const PortMemory, io: std.Io, paths: Paths, bound: u16) void {
    var line: [8]u8 = undefined;
    const text = std.fmt.bufPrint(&line, "{d}\n", .{bound}) catch return;
    ca.writeSecure(io, .{ .path = paths.port, .bytes = text, .exclusive = false }) catch {};

    if (self.own == null and self.legacy == bound) {
        std.Io.Dir.deleteFileAbsolute(io, paths.legacy_port) catch {};
    }

    if (self.reserved.isSet(bound - listener_support.first_port)) {
        scanOthers(io, paths.port, .{ .forget = bound });
    }
}

/// Returns the remembered port when the file holds one inside the proxy
/// range; anything else is forgotten.
fn recall(io: std.Io, directory: std.Io.Dir, sub_path: []const u8) ?u16 {
    var buffer: [16]u8 = undefined;
    const bytes = directory.readFile(io, sub_path, &buffer) catch return null;
    const text = std.mem.trimEnd(u8, bytes, "\r\n");
    const port = std.fmt.parseInt(u16, text, 10) catch return null;
    if (port < listener_support.first_port or port >= listener_support.first_port + listener_support.port_attempts) {
        return null;
    }

    return port;
}

fn scanOthers(io: std.Io, own_path: []const u8, scan: Scan) void {
    const directory_path = std.fs.path.dirname(own_path) orelse return;
    const own_name = std.fs.path.basename(own_path);
    var directory = std.Io.Dir.openDirAbsolute(io, directory_path, .{ .iterate = true }) catch return;
    defer directory.close(io);

    var entries = directory.iterate();
    var scanned: usize = 0;
    while (scanned < max_scanned_entries) : (scanned += 1) {
        const entry = (entries.next(io) catch return) orelse return;
        if (entry.kind != .file or !isPortFile(entry.name) or std.mem.eql(u8, entry.name, own_name)) {
            continue;
        }

        const port = recall(io, directory, entry.name) orelse continue;
        switch (scan) {
            .reserve => |ports| ports.set(port - listener_support.first_port),
            .forget => |bound| {
                if (port == bound) {
                    directory.deleteFile(io, entry.name) catch {};
                }
            },
        }
    }
}

fn isPortFile(name: []const u8) bool {
    if (name.len != file_name_len or !std.mem.startsWith(u8, name, file_prefix)) {
        return false;
    }

    for (name[file_prefix.len..]) |byte| {
        if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) {
            return false;
        }
    }

    return true;
}

const TestDirectory = struct {
    temp: std.testing.TmpDir,
    directory: [std.fs.max_path_bytes]u8 = undefined,
    directory_len: usize = 0,
    legacy: [std.fs.max_path_bytes]u8 = undefined,
    legacy_len: usize = 0,

    fn init(io: std.Io) !TestDirectory {
        var fixture: TestDirectory = .{ .temp = std.testing.tmpDir(.{}) };
        errdefer fixture.temp.cleanup();

        fixture.directory_len = try fixture.temp.dir.realPath(io, &fixture.directory);
        fixture.legacy_len = (try std.fmt.bufPrint(&fixture.legacy, "{s}/proxy-port", .{fixture.directory[0..fixture.directory_len]})).len;
        return fixture;
    }

    fn deinit(self: *TestDirectory) void {
        self.temp.cleanup();
    }

    /// Paths of the runtime at `endpoint`; `buffer` holds its own file.
    fn paths(self: *const TestDirectory, buffer: []u8, endpoint: []const u8) !Paths {
        return .{
            .key = "",
            .certificate = "",
            .bundle = "",
            .secret = "",
            .port = try path(buffer, self.directory[0..self.directory_len], endpoint),
            .legacy_port = self.legacy[0..self.legacy_len],
        };
    }
};

test "each endpoint keeps its own remembered port and ignores foreign values" {
    const io = std.testing.io;
    var fixture = try TestDirectory.init(io);
    defer fixture.deinit();
    var first_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const first = try fixture.paths(&first_buffer, "/run/a.sock");
    var second_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const second = try fixture.paths(&second_buffer, "/run/b.sock");
    var again_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const again = try fixture.paths(&again_buffer, "/run/a.sock");

    try std.testing.expectEqualStrings(first.port, again.port);
    try std.testing.expect(!std.mem.eql(u8, first.port, second.port));
    try std.testing.expect(isPortFile(std.fs.path.basename(first.port)));
    try std.testing.expect(load(io, first).preferred() == null);

    load(io, first).remember(io, first, listener_support.first_port + 3);
    load(io, second).remember(io, second, listener_support.first_port + 5);

    const first_memory = load(io, first);
    try std.testing.expectEqual(@as(?u16, listener_support.first_port + 3), first_memory.preferred());
    try std.testing.expect(first_memory.reserved.isSet(5));
    try std.testing.expect(!first_memory.reserved.isSet(3));
    try std.testing.expectEqual(@as(?u16, listener_support.first_port + 5), load(io, second).preferred());

    try fixture.temp.dir.writeFile(io, .{ .sub_path = std.fs.path.basename(first.port), .data = "80\n" });
    try std.testing.expect(load(io, first).preferred() == null);
    try fixture.temp.dir.writeFile(io, .{ .sub_path = std.fs.path.basename(first.port), .data = "port\n" });
    try std.testing.expect(load(io, first).preferred() == null);
}

test "a runtime without its own file migrates onto the shared port only when it binds it" {
    const io = std.testing.io;
    var fixture = try TestDirectory.init(io);
    defer fixture.deinit();
    var displaced_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const displaced = try fixture.paths(&displaced_buffer, "/run/dev.sock");
    var owner_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const owner = try fixture.paths(&owner_buffer, "/run/runtime.sock");
    const shared = listener_support.first_port + 4;
    try fixture.temp.dir.writeFile(io, .{ .sub_path = "proxy-port", .data = "45104\n" });

    const displaced_memory = load(io, displaced);
    try std.testing.expectEqual(@as(?u16, shared), displaced_memory.preferred());
    displaced_memory.remember(io, displaced, shared + 1);
    try std.testing.expectEqual(@as(?u16, shared), recall(io, std.Io.Dir.cwd(), owner.legacy_port));

    const owner_memory = load(io, owner);
    try std.testing.expectEqual(@as(?u16, shared), owner_memory.preferred());
    owner_memory.remember(io, owner, shared);
    try std.testing.expect(recall(io, std.Io.Dir.cwd(), owner.legacy_port) == null);
    try std.testing.expectEqual(@as(?u16, shared), load(io, owner).preferred());
    try std.testing.expectEqual(@as(?u16, shared + 1), load(io, displaced).preferred());
}

test "the shared port reserves itself for others once a runtime has its own" {
    const io = std.testing.io;
    var fixture = try TestDirectory.init(io);
    defer fixture.deinit();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const paths_value = try fixture.paths(&buffer, "/run/dev.sock");
    load(io, paths_value).remember(io, paths_value, listener_support.first_port + 1);
    try fixture.temp.dir.writeFile(io, .{ .sub_path = "proxy-port", .data = "45104\n" });

    const memory = load(io, paths_value);
    try std.testing.expectEqual(@as(?u16, listener_support.first_port + 1), memory.preferred());
    try std.testing.expect(memory.reserved.isSet(4));
}

test "binding a port another runtime remembers forgets that runtime's claim" {
    const io = std.testing.io;
    var fixture = try TestDirectory.init(io);
    defer fixture.deinit();
    var loser_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const loser = try fixture.paths(&loser_buffer, "/run/loser.sock");
    var winner_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const winner = try fixture.paths(&winner_buffer, "/run/winner.sock");
    var bystander_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const bystander = try fixture.paths(&bystander_buffer, "/run/bystander.sock");
    load(io, loser).remember(io, loser, listener_support.first_port + 2);
    load(io, bystander).remember(io, bystander, listener_support.first_port + 7);
    try fixture.temp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "45102\n" });

    load(io, winner).remember(io, winner, listener_support.first_port + 2);

    try std.testing.expect(load(io, loser).preferred() == null);
    try std.testing.expectEqual(@as(?u16, listener_support.first_port + 2), load(io, winner).preferred());
    try std.testing.expectEqual(@as(?u16, listener_support.first_port + 7), load(io, bystander).preferred());
    _ = try fixture.temp.dir.statFile(io, "notes.txt", .{});
}
