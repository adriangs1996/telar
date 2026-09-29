//! The listener port each runtime bound last time, kept in the proxy
//! directory as `proxy-port-<endpoint key>`, so a process that inherited
//! `HTTPS_PROXY` keeps its destination across its runtime's restarts even
//! when other runtimes share the directory. A file holds the port and the
//! runtime's socket path; the file of a runtime whose socket directory is
//! gone is removed. Earlier versions kept one shared `proxy-port`; only the
//! runtime on the default socket inherits it, preferring that port and
//! retiring the shared file once it binds it and records its own. Losing a
//! file only costs that stability.

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
/// Longest port line: five digits and a newline.
const max_port_line = 8;

/// The port this runtime bound last time.
own: ?u16 = null,
/// The port in the shared file of earlier versions, for the runtime on the
/// default socket only.
legacy: ?u16 = null,
/// Ports that other runtimes sharing the directory remember.
reserved: PortSet = .initEmpty(),

const Scan = union(enum) {
    /// Collect every other runtime's port, removing the files of runtimes
    /// whose socket directory is gone.
    reserve: *PortSet,
    /// Remove every other runtime's file that records this port.
    forget: u16,
};

/// What one port file says.
const Record = struct {
    port: u16,
    /// The socket path of the runtime that wrote it; null when the file
    /// names none.
    endpoint: ?[]const u8,
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
/// shared port of earlier versions when this runtime may inherit it, and the
/// ports other runtimes keep. The shared port counts as another runtime's
/// once this one has its own.
///
/// ```zig
/// const memory = PortMemory.load(io, paths);
/// var listener = try Listener.bind(io, memory.preferred(), &memory.reserved);
/// ```
pub fn load(io: std.Io, paths: Paths) PortMemory {
    var memory: PortMemory = .{
        .own = recallPort(io, paths.port),
        .legacy = if (paths.legacy_port) |legacy_path| recallPort(io, legacy_path) else null,
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
/// directory keeps at most one file per port. When the runtime's own file
/// cannot be written nothing else changes, so the next start still finds
/// the shared port. Failure is not an error: the proxy runs on the port it
/// bound either way.
///
/// ```zig
/// memory.remember(io, paths, listener.port());
/// ```
pub fn remember(self: *const PortMemory, io: std.Io, paths: Paths, bound: u16) void {
    var content: [max_port_line + std.fs.max_path_bytes + 1]u8 = undefined;
    const text = std.fmt.bufPrint(&content, "{d}\n{s}\n", .{ bound, paths.endpoint }) catch return;
    ca.writeSecure(io, .{ .path = paths.port, .bytes = text, .exclusive = false }) catch return;

    if (self.own == null and self.legacy == bound) {
        if (paths.legacy_port) |legacy_path| {
            std.Io.Dir.cwd().deleteFile(io, legacy_path) catch {};
        }
    }

    if (self.reserved.isSet(bound - listener_support.first_port)) {
        scanOthers(io, paths.port, .{ .forget = bound });
    }
}

fn recallPort(io: std.Io, file_path: []const u8) ?u16 {
    var buffer: [max_port_line + std.fs.max_path_bytes + 1]u8 = undefined;
    const record = recall(io, std.Io.Dir.cwd(), file_path, &buffer) orelse return null;
    return record.port;
}

/// Reads a port file: a port inside the proxy range on the first line, then
/// optionally the writer's socket path. Anything else is forgotten.
fn recall(io: std.Io, directory: std.Io.Dir, sub_path: []const u8, buffer: []u8) ?Record {
    const bytes = directory.readFile(io, sub_path, buffer) catch return null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const port_line = std.mem.trimEnd(u8, lines.first(), "\r");
    const port = std.fmt.parseInt(u16, port_line, 10) catch return null;
    if (port < listener_support.first_port or port >= listener_support.first_port + listener_support.port_attempts) {
        return null;
    }

    const endpoint = std.mem.trimEnd(u8, lines.next() orelse "", "\r");
    return .{
        .port = port,
        .endpoint = if (endpoint.len == 0) null else endpoint,
    };
}

/// Whether the directory that held a runtime's socket no longer exists, so
/// that runtime cannot come back at the same path. Only a missing directory
/// counts; any other failure keeps the file.
fn vanished(io: std.Io, endpoint: []const u8) bool {
    if (!std.fs.path.isAbsolute(endpoint)) {
        return false;
    }

    const socket_directory = std.fs.path.dirname(endpoint) orelse return false;
    _ = std.Io.Dir.cwd().statFile(io, socket_directory, .{}) catch |err| return err == error.FileNotFound;
    return false;
}

fn scanOthers(io: std.Io, own_path: []const u8, scan: Scan) void {
    const directory_path = std.fs.path.dirname(own_path) orelse return;
    const own_name = std.fs.path.basename(own_path);
    var directory = std.Io.Dir.cwd().openDir(io, directory_path, .{ .iterate = true }) catch return;
    defer directory.close(io);

    var buffer: [max_port_line + std.fs.max_path_bytes + 1]u8 = undefined;
    var entries = directory.iterate();
    var scanned: usize = 0;
    while (scanned < max_scanned_entries) : (scanned += 1) {
        const entry = (entries.next(io) catch return) orelse return;
        if (entry.kind != .file or !isPortFile(entry.name) or std.mem.eql(u8, entry.name, own_name)) {
            continue;
        }

        const record = recall(io, directory, entry.name, &buffer) orelse continue;
        switch (scan) {
            .reserve => |ports| {
                if (record.endpoint != null and vanished(io, record.endpoint.?)) {
                    directory.deleteFile(io, entry.name) catch {};
                    continue;
                }

                ports.set(record.port - listener_support.first_port);
            },
            .forget => |bound| {
                if (record.port == bound) {
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

/// Whether a test runtime inherits the shared port of earlier versions.
const Inheritance = enum {
    default_socket,
    other_socket,
};

/// Storage for one test runtime's paths.
const TestRuntime = struct {
    port: [std.fs.max_path_bytes]u8 = undefined,
    endpoint: [std.fs.max_path_bytes]u8 = undefined,
};

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

    /// Paths of the runtime whose socket is `name` inside the fixture's
    /// directory, so its socket directory exists.
    fn paths(self: *const TestDirectory, storage: *TestRuntime, name: []const u8, inheritance: Inheritance) !Paths {
        const directory = self.directory[0..self.directory_len];
        const endpoint = try std.fmt.bufPrint(&storage.endpoint, "{s}/{s}", .{ directory, name });
        return .{
            .key = "",
            .certificate = "",
            .bundle = "",
            .secret = "",
            .port = try path(&storage.port, directory, endpoint),
            .legacy_port = if (inheritance == .default_socket) self.legacy[0..self.legacy_len] else null,
            .endpoint = endpoint,
        };
    }
};

test "each endpoint keeps its own remembered port and ignores foreign values" {
    const io = std.testing.io;
    var fixture = try TestDirectory.init(io);
    defer fixture.deinit();
    var first_storage: TestRuntime = .{};
    const first = try fixture.paths(&first_storage, "a.sock", .other_socket);
    var second_storage: TestRuntime = .{};
    const second = try fixture.paths(&second_storage, "b.sock", .other_socket);
    var again_storage: TestRuntime = .{};
    const again = try fixture.paths(&again_storage, "a.sock", .other_socket);

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

test "only the default socket migrates onto the shared port, and only when it binds it" {
    const io = std.testing.io;
    var fixture = try TestDirectory.init(io);
    defer fixture.deinit();
    var development_storage: TestRuntime = .{};
    const development = try fixture.paths(&development_storage, "dev.sock", .other_socket);
    var storage: TestRuntime = .{};
    const runtime = try fixture.paths(&storage, "runtime.sock", .default_socket);
    const shared = listener_support.first_port + 4;
    try fixture.temp.dir.writeFile(io, .{ .sub_path = "proxy-port", .data = "45104\n" });

    try std.testing.expect(load(io, development).preferred() == null);

    // The shared port was taken: the runtime records another and leaves the
    // shared file alone.
    const displaced = load(io, runtime);
    try std.testing.expectEqual(@as(?u16, shared), displaced.preferred());
    displaced.remember(io, runtime, shared + 1);
    try std.testing.expectEqual(@as(?u16, shared), recallPort(io, runtime.legacy_port.?));

    try fixture.temp.dir.deleteFile(io, std.fs.path.basename(runtime.port));
    const migrating = load(io, runtime);
    try std.testing.expectEqual(@as(?u16, shared), migrating.preferred());
    migrating.remember(io, runtime, shared);
    try std.testing.expect(recallPort(io, runtime.legacy_port.?) == null);
    try std.testing.expectEqual(@as(?u16, shared), load(io, runtime).preferred());
}

test "a runtime that cannot record its port keeps the shared one for next time" {
    const io = std.testing.io;
    var fixture = try TestDirectory.init(io);
    defer fixture.deinit();
    var storage: TestRuntime = .{};
    const runtime = try fixture.paths(&storage, "runtime.sock", .default_socket);
    try fixture.temp.dir.writeFile(io, .{ .sub_path = "proxy-port", .data = "45104\n" });
    // A directory where the port file belongs makes the write fail.
    try fixture.temp.dir.createDir(io, std.fs.path.basename(runtime.port), .default_dir);

    const memory = load(io, runtime);
    memory.remember(io, runtime, listener_support.first_port + 4);

    try std.testing.expectEqual(@as(?u16, listener_support.first_port + 4), recallPort(io, runtime.legacy_port.?));
}

test "the shared port reserves itself for others once a runtime has its own" {
    const io = std.testing.io;
    var fixture = try TestDirectory.init(io);
    defer fixture.deinit();
    var storage: TestRuntime = .{};
    const runtime = try fixture.paths(&storage, "runtime.sock", .default_socket);
    load(io, runtime).remember(io, runtime, listener_support.first_port + 1);
    try fixture.temp.dir.writeFile(io, .{ .sub_path = "proxy-port", .data = "45104\n" });

    const memory = load(io, runtime);
    try std.testing.expectEqual(@as(?u16, listener_support.first_port + 1), memory.preferred());
    try std.testing.expect(memory.reserved.isSet(4));
}

test "binding a port another runtime remembers forgets that runtime's claim" {
    const io = std.testing.io;
    var fixture = try TestDirectory.init(io);
    defer fixture.deinit();
    var loser_storage: TestRuntime = .{};
    const loser = try fixture.paths(&loser_storage, "loser.sock", .other_socket);
    var winner_storage: TestRuntime = .{};
    const winner = try fixture.paths(&winner_storage, "winner.sock", .other_socket);
    var bystander_storage: TestRuntime = .{};
    const bystander = try fixture.paths(&bystander_storage, "bystander.sock", .other_socket);
    load(io, loser).remember(io, loser, listener_support.first_port + 2);
    load(io, bystander).remember(io, bystander, listener_support.first_port + 7);
    try fixture.temp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "45102\n" });

    load(io, winner).remember(io, winner, listener_support.first_port + 2);

    try std.testing.expect(load(io, loser).preferred() == null);
    try std.testing.expectEqual(@as(?u16, listener_support.first_port + 2), load(io, winner).preferred());
    try std.testing.expectEqual(@as(?u16, listener_support.first_port + 7), load(io, bystander).preferred());
    _ = try fixture.temp.dir.statFile(io, "notes.txt", .{});
}

test "the file of a runtime whose socket directory is gone is removed" {
    const io = std.testing.io;
    var fixture = try TestDirectory.init(io);
    defer fixture.deinit();
    var storage: TestRuntime = .{};
    const runtime = try fixture.paths(&storage, "runtime.sock", .other_socket);
    var living_storage: TestRuntime = .{};
    const living = try fixture.paths(&living_storage, "living.sock", .other_socket);
    load(io, living).remember(io, living, listener_support.first_port + 6);

    var gone_endpoint: [std.fs.max_path_bytes]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&gone_endpoint, "{s}/deleted-worktree/r.sock", .{fixture.directory[0..fixture.directory_len]});
    var gone_port: [std.fs.max_path_bytes]u8 = undefined;
    const gone_path = try path(&gone_port, fixture.directory[0..fixture.directory_len], endpoint);
    try fixture.temp.dir.writeFile(io, .{ .sub_path = std.fs.path.basename(gone_path), .data = "45109\n/nowhere/r.sock\n" });

    const memory = load(io, runtime);

    try std.testing.expect(!memory.reserved.isSet(9));
    try std.testing.expect(memory.reserved.isSet(6));
    try std.testing.expectError(error.FileNotFound, fixture.temp.dir.statFile(io, std.fs.path.basename(gone_path), .{}));
    _ = try fixture.temp.dir.statFile(io, std.fs.path.basename(living.port), .{});
}

test "a relative proxy directory is neither scanned into a crash nor written" {
    const io = std.testing.io;
    const relative: Paths = .{
        .key = "",
        .certificate = "",
        .bundle = "",
        .secret = "",
        .port = "telar-missing-proxy-directory/proxy-port-0000000000000000",
        .legacy_port = "telar-missing-proxy-directory/proxy-port",
        .endpoint = "relative.sock",
    };

    const memory = load(io, relative);
    try std.testing.expect(memory.preferred() == null);
    memory.remember(io, relative, listener_support.first_port);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, "telar-missing-proxy-directory", .{}));
}
