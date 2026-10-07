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
            // The new port record is already committed; inability to remove the obsolete legacy record does not undo the bound listener.
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
                    // Stale port-record deletion is best effort; a vanished endpoint is not reserved even when its old file cannot be removed.
                    directory.deleteFile(io, entry.name) catch {};
                    continue;
                }

                ports.set(record.port - listener_support.first_port);
            },
            .forget => |bound| {
                if (record.port == bound) {
                    // A stale duplicate port record may remain if cleanup fails; listener binding remains the authority on whether the port is available.
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
