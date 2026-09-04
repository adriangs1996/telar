//! Explicit, reversible installation of Telar's short-lived system-trust CA.

const std = @import("std");
const backend = @import("telar-backend");
const parser = @import("parser.zig");

const Io = std.Io;
const File = Io.File;
const ca = backend.proxy.ca;
const rotation_window_seconds: u64 = 24 * 60 * 60;
const record_name = "trust-install.json";
const system_key_name = "ca-system-key.pem";
const system_cert_name = "ca-system-cert.pem";
const linux_certificate_path = "/usr/local/share/ca-certificates/telar-proxy.crt";

pub const TrustBackend = enum {
    macos,
    update_ca_certificates,
    trust,
};

pub const Status = enum {
    absent,
    installed,
    stale,
};

pub const Record = struct {
    backend: TrustBackend,
    fingerprint: [40]u8,
    store_path: [std.fs.max_path_bytes]u8 = undefined,
    store_path_len: u16 = 0,

    /// Borrows the validated absolute trust-store path from this fixed record.
    ///
    /// ```zig
    /// const destination = record.storePath();
    /// ```
    pub fn storePath(record: *const Record) []const u8 {
        return record.store_path[0..record.store_path_len];
    }
};

const JsonRecord = struct {
    version: u8,
    backend: []const u8,
    fingerprint: []const u8,
    store_path: []const u8,
};

const AuthorityPaths = struct {
    key: [std.fs.max_path_bytes]u8 = undefined,
    key_len: usize,
    certificate: [std.fs.max_path_bytes]u8 = undefined,
    certificate_len: usize,
    record: [std.fs.max_path_bytes]u8 = undefined,
    record_len: usize,

    fn init(directory: []const u8) !AuthorityPaths {
        var paths: AuthorityPaths = .{ .key_len = 0, .certificate_len = 0, .record_len = 0 };
        paths.key_len = (try std.fmt.bufPrint(&paths.key, "{s}/{s}", .{ directory, system_key_name })).len;
        paths.certificate_len = (try std.fmt.bufPrint(&paths.certificate, "{s}/{s}", .{ directory, system_cert_name })).len;
        paths.record_len = (try std.fmt.bufPrint(&paths.record, "{s}/{s}", .{ directory, record_name })).len;
        return paths;
    }

    fn files(paths: *const AuthorityPaths) ca.AuthorityFiles {
        return .{ .key = paths.key[0..paths.key_len], .certificate = paths.certificate[0..paths.certificate_len] };
    }

    fn recordPath(paths: *const AuthorityPaths) []const u8 {
        return paths.record[0..paths.record_len];
    }
};

const PreparedAuthority = struct {
    authority: ca.Authority,
    temporary_key: [std.fs.max_path_bytes]u8 = undefined,
    temporary_key_len: usize = 0,
    temporary_certificate: [std.fs.max_path_bytes]u8 = undefined,
    temporary_certificate_len: usize = 0,
    temporary: bool = false,

    fn files(prepared: *const PreparedAuthority, canonical: *const AuthorityPaths) ca.AuthorityFiles {
        if (!prepared.temporary) {
            return canonical.files();
        }

        return .{
            .key = prepared.temporary_key[0..prepared.temporary_key_len],
            .certificate = prepared.temporary_certificate[0..prepared.temporary_certificate_len],
        };
    }

    fn cleanup(prepared: *PreparedAuthority, io: Io) void {
        if (!prepared.temporary) {
            return;
        }

        Io.Dir.deleteFileAbsolute(io, prepared.temporary_key[0..prepared.temporary_key_len]) catch {};
        Io.Dir.deleteFileAbsolute(io, prepared.temporary_certificate[0..prepared.temporary_certificate_len]) catch {};
    }
};

/// Runs `telar proxy trust install|uninstall|status` without contacting the
/// runtime.
///
/// ```zig
/// std.process.exit(try proxy.run(init, options));
/// ```
pub fn run(init: std.process.Init, options: parser.ProxyOptions) !u8 {
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = if (options.ca_dir) |value|
        std.mem.span(value)
    else
        try defaultDirectory(init.minimal.environ, &directory_buffer);
    if (!std.fs.path.isAbsolute(directory)) {
        std.debug.print("telar proxy trust: --ca-dir must be absolute\n", .{});
        return 1;
    }

    var output_buffer: [4096]u8 = undefined;
    var output = File.stdout().writerStreaming(init.io, &output_buffer);
    const writer = &output.interface;
    defer writer.flush() catch {};

    const paths = try AuthorityPaths.init(directory);
    const current = inspect(.fromProcess(init), &paths);
    switch (options.action) {
        .status => {
            try writer.print("telar proxy trust: {s} ({s})\n", .{ @tagName(current.status), directory });
            if (current.record) |record| {
                try writer.print("fingerprint: {s}\nstore: {s}\n", .{ &record.fingerprint, record.storePath() });
            }
            try printFirefoxNotice(writer, paths.files().certificate);
            return if (current.status == .stale) 1 else 0;
        },
        .install => {
            if (current.status == .stale and current.record == null) {
                try writer.print("telar proxy trust: invalid trust record ({s})\n", .{paths.recordPath()});
                return 1;
            }

            const selected_backend = try selectBackend(options.linux_backend);
            if (current.status == .installed and current.record.?.backend == selected_backend) {
                try writer.print("telar proxy trust: already installed ({s})\n", .{directory});
                try printFirefoxNotice(writer, paths.files().certificate);
                return 0;
            }

            try prepareDirectory(init.io, directory);
            try install(init, .{ .paths = paths, .previous = current.record, .backend = selected_backend, .writer = writer });
            try printFirefoxNotice(writer, paths.files().certificate);
            return 0;
        },
        .uninstall => {
            if (current.status == .stale and current.record == null) {
                try writer.print("telar proxy trust: invalid trust record ({s})\n", .{paths.recordPath()});
                return 1;
            }

            const record = current.record orelse {
                try writer.print("telar proxy trust: not installed ({s})\n", .{directory});
                return 0;
            };
            try uninstallRecord(.{ .init = init, .writer = writer }, record, paths.files().certificate);
            try Io.Dir.deleteFileAbsolute(init.io, paths.recordPath());
            try writer.print("telar proxy trust: removed {s}\n", .{&record.fingerprint});
            return 0;
        },
    }
}

const Inspection = struct {
    status: Status,
    record: ?Record,
};

const InspectionContext = struct {
    io: Io,
    gpa: std.mem.Allocator,
    environ: std.process.Environ,

    fn fromProcess(init: std.process.Init) InspectionContext {
        return .{ .io = init.io, .gpa = init.gpa, .environ = init.minimal.environ };
    }
};

const InstallOptions = struct {
    paths: AuthorityPaths,
    previous: ?Record,
    backend: TrustBackend,
    writer: *Io.Writer,
};

const AuthorityTarget = struct {
    backend: TrustBackend,
    certificate: []const u8,
};

const AuthorityCommand = struct {
    init: std.process.Init,
    writer: *Io.Writer,
};

/// Reports whether the record, files, fingerprint, and lifetime prove that
/// Telar's system authority is installed.
///
/// ```zig
/// if (proxy.trusted(init, directory)) showBadge();
/// ```
pub fn trusted(init: std.process.Init, directory: []const u8) bool {
    const paths = AuthorityPaths.init(directory) catch return false;
    return inspect(.fromProcess(init), &paths).status == .installed;
}

/// Rotates an installed CA during server startup when less than one day of
/// its 30-day validity remains. An absent trust record is a no-op.
pub fn rotateIfNeeded(init: std.process.Init, directory: []const u8) !bool {
    const paths = try AuthorityPaths.init(directory);
    const current = inspect(.fromProcess(init), &paths);
    if (current.status != .stale or current.record == null) {
        return false;
    }

    try prepareDirectory(init.io, directory);

    var output_buffer: [4096]u8 = undefined;
    var output = File.stderr().writerStreaming(init.io, &output_buffer);
    defer output.interface.flush() catch {};
    try install(init, .{ .paths = paths, .previous = current.record, .backend = current.record.?.backend, .writer = &output.interface });
    return true;
}

fn inspect(context: InspectionContext, paths: *const AuthorityPaths) Inspection {
    const record = readRecord(context.io, context.gpa, paths.recordPath()) catch return .{ .status = .stale, .record = null };
    const stored = record orelse return .{ .status = .absent, .record = null };
    validateRecordTarget(context.environ, stored, paths.files().certificate) catch
        return .{ .status = .stale, .record = stored };
    validateDirectory(context.io, std.fs.path.dirname(paths.recordPath()) orelse return .{ .status = .stale, .record = stored }) catch
        return .{ .status = .stale, .record = stored };
    const authority = ca.Authority.loadExisting(.{ .io = context.io, .allocator = context.gpa }, paths.files()) catch
        return .{ .status = .stale, .record = stored };
    if (!std.mem.eql(u8, &authority.fingerprint(), &stored.fingerprint)) {
        return .{ .status = .stale, .record = stored };
    }
    if (!(authority.hasSystemLifetime() catch false)) {
        return .{ .status = .stale, .record = stored };
    }
    if (authority.expiresWithin(context.io, rotation_window_seconds) catch true) {
        return .{ .status = .stale, .record = stored };
    }

    return .{ .status = .installed, .record = stored };
}

fn install(init: std.process.Init, options: InstallOptions) !void {
    if (options.previous) |record| {
        try validateRecordTarget(init.minimal.environ, record, options.paths.files().certificate);
    }

    var prepared = try prepareAuthority(init, &options.paths);
    defer prepared.cleanup(init.io);
    const fingerprint = prepared.authority.fingerprint();
    const prepared_files = prepared.files(&options.paths);
    var rollback_certificate = prepared_files.certificate;
    var store_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try storePath(init.minimal.environ, .{
        .backend = options.backend,
        .certificate = options.paths.files().certificate,
    }, &store_path_buffer);

    try installAuthority(.{ .init = init, .writer = options.writer }, .{
        .backend = options.backend,
        .certificate = prepared_files.certificate,
    }, store_path);
    errdefer uninstallAuthority(init, options.backend, &fingerprint, rollback_certificate, store_path, options.writer) catch {};
    if (options.previous) |old| {
        if (removePreviousSeparately(old.backend, options.backend)) {
            try uninstallAuthority(init, old.backend, &old.fingerprint, options.paths.files().certificate, old.storePath(), options.writer);
        }
    }
    if (prepared.temporary) {
        try activatePrepared(init.io, &prepared, &options.paths);
        rollback_certificate = options.paths.files().certificate;
    }

    const record = try makeRecord(options.backend, fingerprint, store_path);
    try writeRecord(init.io, options.paths.recordPath(), record);
    try options.writer.print("telar proxy trust: installed {s}\n", .{&fingerprint});
}

fn prepareAuthority(init: std.process.Init, paths: *const AuthorityPaths) !PreparedAuthority {
    const resources: ca.Resources = .{ .io = init.io, .allocator = init.gpa };
    if (ca.Authority.loadExisting(resources, paths.files())) |authority| {
        if (try authority.hasSystemLifetime() and !(try authority.expiresWithin(init.io, rotation_window_seconds))) {
            return .{ .authority = authority };
        }
    } else |_| {}

    var nonce: [8]u8 = undefined;
    try init.io.randomSecure(&nonce);
    const suffix = std.fmt.bytesToHex(nonce, .lower);
    var prepared: PreparedAuthority = undefined;
    prepared.temporary_key_len = (try std.fmt.bufPrint(&prepared.temporary_key, "{s}.rotate-{s}", .{ paths.files().key, &suffix })).len;
    prepared.temporary_certificate_len = (try std.fmt.bufPrint(&prepared.temporary_certificate, "{s}.rotate-{s}", .{ paths.files().certificate, &suffix })).len;
    const files: ca.AuthorityFiles = .{
        .key = prepared.temporary_key[0..prepared.temporary_key_len],
        .certificate = prepared.temporary_certificate[0..prepared.temporary_certificate_len],
    };
    errdefer Io.Dir.deleteFileAbsolute(init.io, files.key) catch {};
    errdefer Io.Dir.deleteFileAbsolute(init.io, files.certificate) catch {};
    prepared.temporary = true;
    prepared.authority = try ca.Authority.createSystem(resources, files);
    return prepared;
}

fn activatePrepared(io: Io, prepared: *PreparedAuthority, paths: *const AuthorityPaths) !void {
    const files = prepared.files(paths);
    const canonical = paths.files();
    var nonce: [8]u8 = undefined;
    try io.randomSecure(&nonce);
    const suffix = std.fmt.bytesToHex(nonce, .lower);
    var backup_key_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var backup_certificate_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const backup_key = try std.fmt.bufPrint(&backup_key_buffer, "{s}.previous-{s}", .{ canonical.key, &suffix });
    const backup_certificate = try std.fmt.bufPrint(&backup_certificate_buffer, "{s}.previous-{s}", .{ canonical.certificate, &suffix });

    const had_key = try fileExists(io, canonical.key);
    if (had_key) {
        try Io.Dir.renameAbsolute(canonical.key, backup_key, io);
    }
    errdefer if (had_key) Io.Dir.renameAbsolute(backup_key, canonical.key, io) catch {};

    const had_certificate = try fileExists(io, canonical.certificate);
    if (had_certificate) {
        try Io.Dir.renameAbsolute(canonical.certificate, backup_certificate, io);
    }
    errdefer if (had_certificate) Io.Dir.renameAbsolute(backup_certificate, canonical.certificate, io) catch {};

    try Io.Dir.renameAbsolute(files.key, canonical.key, io);
    errdefer Io.Dir.renameAbsolute(canonical.key, files.key, io) catch {};
    try Io.Dir.renameAbsolute(files.certificate, canonical.certificate, io);
    errdefer Io.Dir.renameAbsolute(canonical.certificate, files.certificate, io) catch {};

    prepared.temporary = false;
    if (had_certificate) {
        Io.Dir.deleteFileAbsolute(io, backup_certificate) catch {};
    }
    if (had_key) {
        Io.Dir.deleteFileAbsolute(io, backup_key) catch {};
    }
}

fn fileExists(io: Io, path: []const u8) !bool {
    Io.Dir.accessAbsolute(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |other| return other,
    };

    return true;
}

fn selectBackend(selected: ?parser.LinuxTrustBackend) !TrustBackend {
    return switch (@import("builtin").os.tag) {
        .macos => if (selected == null) .macos else error.LinuxTrustFlagOnMacOS,
        .linux => switch (selected orelse return error.LinuxTrustBackendRequired) {
            .update_ca_certificates => .update_ca_certificates,
            .trust => .trust,
        },
        else => error.UnsupportedTrustPlatform,
    };
}

fn validateBackend(selected: TrustBackend) !void {
    switch (@import("builtin").os.tag) {
        .macos => if (selected != .macos) return error.UnsupportedTrustRecord,
        .linux => if (selected == .macos) return error.UnsupportedTrustRecord,
        else => return error.UnsupportedTrustPlatform,
    }
}

fn storePath(environ: std.process.Environ, target: AuthorityTarget, buffer: []u8) ![]const u8 {
    return switch (target.backend) {
        .macos => block: {
            const home = environ.getPosix("HOME") orelse return error.HomeUnavailable;
            break :block try std.fmt.bufPrint(buffer, "{s}/Library/Keychains/login.keychain-db", .{home});
        },
        .update_ca_certificates => linux_certificate_path,
        .trust => target.certificate,
    };
}

fn removePreviousSeparately(previous: TrustBackend, replacement: TrustBackend) bool {
    return previous != .update_ca_certificates or replacement != .update_ca_certificates;
}

fn validateRecordTarget(environ: std.process.Environ, record: Record, certificate: []const u8) !void {
    try validateBackend(record.backend);

    var expected_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const expected = try storePath(environ, .{ .backend = record.backend, .certificate = certificate }, &expected_buffer);
    if (!std.mem.eql(u8, expected, record.storePath())) {
        return error.InvalidTrustRecord;
    }
}

fn installAuthority(command: AuthorityCommand, target: AuthorityTarget, destination: []const u8) !void {
    switch (target.backend) {
        .macos => try runCommand(command.init, &.{ "/usr/bin/security", "add-trusted-cert", "-r", "trustRoot", "-k", destination, target.certificate }, command.writer),
        .update_ca_certificates => {
            try runCommand(command.init, &.{ "sudo", "--", "install", "-m", "0644", target.certificate, destination }, command.writer);
            try runCommand(command.init, &.{ "sudo", "--", "update-ca-certificates" }, command.writer);
        },
        .trust => try runCommand(command.init, &.{ "sudo", "--", "trust", "anchor", target.certificate }, command.writer),
    }
}

fn uninstallRecord(command: AuthorityCommand, record: Record, certificate: []const u8) !void {
    try validateRecordTarget(command.init.minimal.environ, record, certificate);

    return uninstallAuthority(command.init, record.backend, &record.fingerprint, certificate, record.storePath(), command.writer);
}

fn uninstallAuthority(init: std.process.Init, selected: TrustBackend, fingerprint: []const u8, certificate: []const u8, destination: []const u8, writer: *Io.Writer) !void {
    switch (selected) {
        .macos => try runCommand(init, &.{ "/usr/bin/security", "delete-certificate", "-Z", fingerprint, destination }, writer),
        .update_ca_certificates => {
            try runCommand(init, &.{ "sudo", "--", "rm", "-f", destination }, writer);
            try runCommand(init, &.{ "sudo", "--", "update-ca-certificates" }, writer);
        },
        .trust => try runCommand(init, &.{ "sudo", "--", "trust", "anchor", "--remove", certificate }, writer),
    }
}

fn runCommand(init: std.process.Init, argv: []const []const u8, writer: *Io.Writer) !void {
    try writer.writeAll("telar proxy trust: exec");
    for (argv) |argument| {
        try writer.print(" {f}", .{std.json.fmt(argument, .{})});
    }
    try writer.writeByte('\n');
    try writer.flush();

    var child = try std.process.spawn(init.io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const result = try child.wait(init.io);
    switch (result) {
        .exited => |status| if (status != 0) return error.TrustCommandFailed,
        else => return error.TrustCommandFailed,
    }
}

fn makeRecord(selected: TrustBackend, fingerprint: [40]u8, store_path: []const u8) !Record {
    if (store_path.len == 0 or store_path.len > std.fs.max_path_bytes or !std.fs.path.isAbsolute(store_path)) {
        return error.InvalidTrustRecord;
    }

    var record: Record = .{ .backend = selected, .fingerprint = fingerprint };
    @memcpy(record.store_path[0..store_path.len], store_path);
    record.store_path_len = @intCast(store_path.len);
    return record;
}

fn readRecord(io: Io, gpa: std.mem.Allocator, path: []const u8) !?Record {
    const stat = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0) {
        return error.InvalidTrustRecord;
    }

    const source = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4096)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer gpa.free(source);
    const parsed = try std.json.parseFromSlice(JsonRecord, gpa, source, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    if (parsed.value.version != 1 or parsed.value.fingerprint.len != 40) {
        return error.InvalidTrustRecord;
    }
    for (parsed.value.fingerprint) |byte| {
        if (!std.ascii.isHex(byte)) {
            return error.InvalidTrustRecord;
        }
    }

    const selected: TrustBackend = if (std.mem.eql(u8, parsed.value.backend, "macos"))
        .macos
    else if (std.mem.eql(u8, parsed.value.backend, "update-ca-certificates"))
        .update_ca_certificates
    else if (std.mem.eql(u8, parsed.value.backend, "trust"))
        .trust
    else
        return error.InvalidTrustRecord;
    var fingerprint: [40]u8 = undefined;
    for (parsed.value.fingerprint, &fingerprint) |byte, *destination| destination.* = std.ascii.toUpper(byte);
    return try makeRecord(selected, fingerprint, parsed.value.store_path);
}

fn writeRecord(io: Io, path: []const u8, record: Record) !void {
    var source_buffer: [4096]u8 = undefined;
    const source = try std.fmt.bufPrint(&source_buffer, "{{\n  \"version\": 1,\n  \"backend\": {f},\n  \"fingerprint\": {f},\n  \"store_path\": {f}\n}}\n", .{
        std.json.fmt(switch (record.backend) {
            .macos => "macos",
            .update_ca_certificates => "update-ca-certificates",
            .trust => "trust",
        }, .{}),
        std.json.fmt(&record.fingerprint, .{}),
        std.json.fmt(record.storePath(), .{}),
    });
    try writeSecure(io, path, source);
}

fn writeSecure(io: Io, path: []const u8, source: []const u8) !void {
    var temporary_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var nonce: [8]u8 = undefined;
    for (0..8) |_| {
        try io.randomSecure(&nonce);
        const suffix = std.fmt.bytesToHex(nonce, .lower);
        const temporary = try std.fmt.bufPrint(&temporary_buffer, "{s}.tmp-{s}", .{ path, &suffix });
        const file = Io.Dir.createFileAbsolute(io, temporary, .{
            .read = true,
            .truncate = false,
            .exclusive = true,
            .permissions = File.Permissions.fromMode(0o600),
        }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        file.writeStreamingAll(io, source) catch |err| {
            file.close(io);
            Io.Dir.deleteFileAbsolute(io, temporary) catch {};
            return err;
        };
        file.sync(io) catch |err| {
            file.close(io);
            Io.Dir.deleteFileAbsolute(io, temporary) catch {};
            return err;
        };
        file.close(io);
        Io.Dir.renameAbsolute(temporary, path, io) catch |err| {
            Io.Dir.deleteFileAbsolute(io, temporary) catch {};
            return err;
        };
        return;
    }

    return error.TemporaryPathUnavailable;
}

fn prepareDirectory(io: Io, directory: []const u8) !void {
    const permissions = File.Permissions.fromMode(0o700);
    _ = try Io.Dir.cwd().createDirPathStatus(io, directory, permissions);
    try validateDirectoryOwner(io, directory);
    try Io.Dir.cwd().setFilePermissions(io, directory, permissions, .{ .follow_symlinks = false });
    try validateDirectory(io, directory);
}

fn validateDirectory(io: Io, directory: []const u8) !void {
    try validateDirectoryOwner(io, directory);

    const stat = try Io.Dir.cwd().statFile(io, directory, .{ .follow_symlinks = false });
    if (stat.kind != .directory or stat.permissions.toMode() & 0o077 != 0) {
        return error.InvalidProxyDirectory;
    }
}

fn validateDirectoryOwner(io: Io, directory: []const u8) !void {
    const stat = try Io.Dir.cwd().statFile(io, directory, .{ .follow_symlinks = false });
    if (stat.kind != .directory) {
        return error.InvalidProxyDirectory;
    }

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buffer, "{s}", .{directory}) catch return error.NameTooLong;
    var native_stat: std.c.Stat = undefined;
    if (std.c.fstatat(std.c.AT.FDCWD, path_z, &native_stat, std.c.AT.SYMLINK_NOFOLLOW) != 0) {
        return error.InvalidProxyDirectory;
    }
    if (native_stat.uid != std.c.getuid()) {
        return error.WrongOwner;
    }
}

fn defaultDirectory(environ: std.process.Environ, buffer: []u8) ![]const u8 {
    if (environ.getPosix("XDG_DATA_HOME")) |base| {
        if (base.len != 0) {
            return std.fmt.bufPrint(buffer, "{s}/telar/proxy", .{base});
        }
    }

    const home = environ.getPosix("HOME") orelse return error.HomeUnavailable;
    if (home.len == 0) {
        return error.HomeUnavailable;
    }
    return std.fmt.bufPrint(buffer, "{s}/.local/share/telar/proxy", .{home});
}

fn printFirefoxNotice(writer: *Io.Writer, certificate: []const u8) !void {
    try writer.print("Firefox may use its own certificate store; import {s} there if it does not honor OS trust.\n", .{certificate});
}

test "trust records round trip with owner-only permissions" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    try prepareDirectory(io, directory);
    const paths = try AuthorityPaths.init(directory);
    const fingerprint: [40]u8 = @splat('A');
    const record = try makeRecord(.macos, fingerprint, "/Users/test/Library/Keychains/login.keychain-db");
    try writeRecord(io, paths.recordPath(), record);
    const loaded = (try readRecord(io, std.testing.allocator, paths.recordPath())).?;
    try std.testing.expectEqual(record.backend, loaded.backend);
    try std.testing.expectEqualSlices(u8, &record.fingerprint, &loaded.fingerprint);
    try std.testing.expectEqualStrings(record.storePath(), loaded.storePath());
    const stat = try Io.Dir.cwd().statFile(io, paths.recordPath(), .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
}

test "default proxy trust directory follows XDG then HOME" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("HOME", "/home/test");
    try environment.put("XDG_DATA_HOME", "/data");
    const block = try environment.createPosixBlock(std.testing.allocator, .{});
    defer block.deinit(std.testing.allocator);
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("/data/telar/proxy", try defaultDirectory(.{ .block = block }, &buffer));
}

test "inspection accepts only the recorded short-lived authority" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    try prepareDirectory(io, directory);
    const paths = try AuthorityPaths.init(directory);
    const authority = try ca.Authority.loadOrCreateSystem(.{ .io = io, .allocator = std.testing.allocator }, paths.files());
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("HOME", "/Users/test");
    const block = try environment.createPosixBlock(std.testing.allocator, .{});
    defer block.deinit(std.testing.allocator);
    const environ: std.process.Environ = .{ .block = block };
    const selected: TrustBackend = if (@import("builtin").os.tag == .macos) .macos else .trust;
    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store = try storePath(environ, .{ .backend = selected, .certificate = paths.files().certificate }, &store_buffer);
    const record = try makeRecord(selected, authority.fingerprint(), store);
    try writeRecord(io, paths.recordPath(), record);

    const context: InspectionContext = .{ .io = io, .gpa = std.testing.allocator, .environ = environ };
    const installed = inspect(context, &paths);
    try std.testing.expectEqual(Status.installed, installed.status);

    var changed = record;
    changed.fingerprint[0] = if (changed.fingerprint[0] == 'A') 'B' else 'A';
    try writeRecord(io, paths.recordPath(), changed);
    try std.testing.expectEqual(Status.stale, inspect(context, &paths).status);
}

test "update-ca-certificates rotation keeps the replacement at its fixed path" {
    try std.testing.expect(!removePreviousSeparately(.update_ca_certificates, .update_ca_certificates));
    try std.testing.expect(removePreviousSeparately(.macos, .macos));
    try std.testing.expect(removePreviousSeparately(.trust, .update_ca_certificates));
}

test "Linux trust records cannot redirect privileged removal" {
    const record = try makeRecord(.update_ca_certificates, @splat('A'), "/etc/passwd");
    if (@import("builtin").os.tag == .linux) {
        try std.testing.expectError(error.InvalidTrustRecord, validateRecordTarget(.empty, record, "/tmp/ca-system-cert.pem"));
    } else {
        try std.testing.expectError(error.UnsupportedTrustRecord, validateRecordTarget(.empty, record, "/tmp/ca-system-cert.pem"));
    }
}

test "authority activation replaces the key and certificate as one recoverable pair" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    try prepareDirectory(io, directory);
    const paths = try AuthorityPaths.init(directory);
    const resources: ca.Resources = .{ .io = io, .allocator = std.testing.allocator };
    _ = try ca.Authority.loadOrCreate(resources, paths.files());

    var prepared: PreparedAuthority = undefined;
    prepared.temporary_key_len = (try std.fmt.bufPrint(&prepared.temporary_key, "{s}.new", .{paths.files().key})).len;
    prepared.temporary_certificate_len = (try std.fmt.bufPrint(&prepared.temporary_certificate, "{s}.new", .{paths.files().certificate})).len;
    prepared.temporary = true;
    prepared.authority = try ca.Authority.createSystem(resources, prepared.files(&paths));
    const replacement_fingerprint = prepared.authority.fingerprint();

    try activatePrepared(io, &prepared, &paths);

    const loaded = try ca.Authority.loadExisting(resources, paths.files());
    try std.testing.expectEqualSlices(u8, &replacement_fingerprint, &loaded.fingerprint());
    try std.testing.expect(try loaded.hasSystemLifetime());
}
