//! Plugin inspection, installation and digest-bound trust commands.

const std = @import("std");
const core = @import("telar-core");
const frontend = @import("telar-frontend");
const parser = @import("parser.zig");
const TestEnvironment = @import("test_environment.zig").TestEnvironment;

const Io = std.Io;
const File = Io.File;
const Package = frontend.plugins.Package;
const PluginOptions = parser.PluginOptions;

/// Inspects one package and performs the requested read-only, installation or
/// trust operation without executing plugin code.
///
/// ```zig
/// try plugin.run(process_init, options);
/// ```
pub fn run(init: std.process.Init, options: PluginOptions) !void {
    const package = try frontend.plugins.inspectPackage(init.gpa, init.io, std.mem.span(options.path));
    switch (options.command) {
        .inspect => try printInspection(init.io, &package),
        .install => try install(init, &package),
        .trust => try trust(init, &package, &options),
    }
}

/// Runs one isolated plugin callback process from the already validated
/// internal worker arguments supplied by the client broker.
///
/// ```zig
/// try plugin.runWorker(process_init, options);
/// ```
pub fn runWorker(init: std.process.Init, options: parser.PluginWorkerOptions) !void {
    return frontend.plugins.runWorker(
        init,
        std.mem.span(options.entry),
        std.mem.span(options.action),
        options.context,
    );
}

/// Resolves the trust-store path from XDG_CONFIG_HOME or HOME into the caller's
/// buffer. The returned slice remains valid while that buffer does.
///
/// ```zig
/// const path = try plugin.trustPath(environ, &path_buffer);
/// ```
pub fn trustPath(environ: std.process.Environ, buffer: []u8) ![]const u8 {
    if (environ.getPosix("XDG_CONFIG_HOME")) |base| {
        if (base.len != 0) {
            return std.fmt.bufPrint(buffer, "{s}/telar/trust.json", .{base});
        }
    }

    const home = environ.getPosix("HOME") orelse return error.HomeDirectoryUnavailable;
    if (home.len == 0) {
        return error.HomeDirectoryUnavailable;
    }

    return std.fmt.bufPrint(buffer, "{s}/.config/telar/trust.json", .{home});
}

/// Loads a bounded trust store after verifying that its path is a private,
/// regular file. A missing file represents an empty store.
///
/// ```zig
/// const store = try plugin.loadTrustStore(process_init, path);
/// ```
pub fn loadTrustStore(init: std.process.Init, path: []const u8) !core.plugin.TrustStore {
    return loadStore(init.io, init.gpa, path);
}

fn printInspection(io: Io, package: *const Package) !void {
    var buffer: [4096]u8 = undefined;
    var output = File.stdout().writerStreaming(io, &buffer);
    const writer = &output.interface;
    try writer.print("id: {s}\nversion: {s}\nsource: {s}\nrevision: {s}\ndigest: ", .{
        package.manifest.id(),
        package.manifest.version(),
        package.manifest.source(),
        package.manifest.revision(),
    });
    for (package.digest) |byte| {
        try writer.print("{x:0>2}", .{byte});
    }
    try writer.writeAll("\nactions:");
    for (package.manifest.actions[0..package.manifest.action_count]) |*action| {
        try writer.print(" {s}", .{action.slice()});
    }
    try writer.writeAll("\ncapabilities:");
    var iterator = package.manifest.capabilities.iterator();
    while (iterator.next()) |capability| {
        try writer.print(" {s}", .{capability.canonicalName()});
    }
    try writer.writeByte('\n');
    try writer.flush();
}

fn install(init: std.process.Init, package: *const Package) !void {
    var base_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const base = try installBase(init.minimal.environ, &base_buffer);
    const digest_hex = std.fmt.bytesToHex(package.digest, .lower);
    var destination_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const destination = try std.fmt.bufPrint(&destination_buffer, "{s}/{s}/{s}", .{
        base,
        package.manifest.id(),
        &digest_hex,
    });
    try frontend.plugins.installPackage(init.gpa, init.io, .{ .package = package, .destination = destination });

    var output_buffer: [std.fs.max_path_bytes + 64]u8 = undefined;
    const output = try std.fmt.bufPrint(&output_buffer, "telar plugin installed: {s}\n", .{destination});
    try File.stdout().writeStreamingAll(init.io, output);
}

fn trust(init: std.process.Init, package: *const Package, options: *const PluginOptions) !void {
    const granted = try grantedCapabilities(package.manifest.capabilities, options);
    var trust_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try trustPath(init.minimal.environ, &trust_path_buffer);
    var store = try loadStore(init.io, init.gpa, path);
    try store.upsert(&package.manifest, .{ .digest = package.digest, .capabilities = granted });
    try writeStore(init.io, path, &store);
    try File.stdout().writeStreamingAll(init.io, "telar plugin trust updated\n");
}

fn installBase(environ: std.process.Environ, buffer: []u8) ![]const u8 {
    if (environ.getPosix("XDG_DATA_HOME")) |base| {
        if (base.len != 0) {
            return std.fmt.bufPrint(buffer, "{s}/telar/plugins", .{base});
        }
    }

    const home = environ.getPosix("HOME") orelse return error.HomeDirectoryUnavailable;
    if (home.len == 0) {
        return error.HomeDirectoryUnavailable;
    }

    return std.fmt.bufPrint(buffer, "{s}/.local/share/telar/plugins", .{home});
}

fn grantedCapabilities(declared: core.plugin.CapabilitySet, options: *const PluginOptions) !core.plugin.CapabilitySet {
    if (options.capability_count == 0) {
        return declared;
    }

    var granted = core.plugin.CapabilitySet.initEmpty();
    for (options.capabilities[0..options.capability_count]) |capability| {
        if (!declared.contains(capability)) {
            return error.CapabilityNotDeclared;
        }

        if (granted.contains(capability)) {
            return error.DuplicateCapability;
        }

        granted.insert(capability);
    }

    return granted;
}

fn loadStore(io: Io, gpa: std.mem.Allocator, path: []const u8) !core.plugin.TrustStore {
    const stat = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => |other| return other,
    };
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0) {
        return error.InsecureTrustStore;
    }

    const source = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024));
    defer gpa.free(source);
    return core.plugin.TrustStore.parse(gpa, source);
}

fn writeStore(io: Io, path: []const u8, store: *const core.plugin.TrustStore) !void {
    const directory = std.fs.path.dirname(path) orelse return error.InvalidTrustStorePath;
    _ = try Io.Dir.cwd().createDirPathStatus(io, directory, File.Permissions.fromMode(0o700));
    try Io.Dir.cwd().setFilePermissions(io, directory, File.Permissions.fromMode(0o700), .{ .follow_symlinks = false });

    var nonce: [16]u8 = undefined;
    try io.randomSecure(&nonce);
    const nonce_hex = std.fmt.bytesToHex(nonce, .lower);
    var temp_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const temp = try std.fmt.bufPrint(&temp_buffer, "{s}.tmp-{s}", .{ path, &nonce_hex });
    var committed = false;
    defer if (!committed) {
        Io.Dir.cwd().deleteFile(io, temp) catch {};
    };

    var file = try Io.Dir.cwd().createFile(io, temp, .{
        .truncate = true,
        .permissions = File.Permissions.fromMode(0o600),
    });
    var file_open = true;
    defer if (file_open) {
        file.close(io);
    };
    var output_buffer: [4096]u8 = undefined;
    var output = file.writer(io, &output_buffer);
    try store.writeJson(&output.interface);
    try output.interface.flush();
    try file.sync(io);
    file.close(io);
    file_open = false;
    try Io.Dir.cwd().rename(temp, Io.Dir.cwd(), path, io);
    committed = true;
}

fn temporaryPath(temp: *std.testing.TmpDir, name: []const u8, buffer: []u8) ![]const u8 {
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(std.testing.io, &directory_buffer);
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ directory_buffer[0..directory_len], name });
}

test "plugin data and trust paths prefer their XDG homes" {
    var environment = try TestEnvironment.init(&.{
        .{ "XDG_DATA_HOME", "/data" },
        .{ "XDG_CONFIG_HOME", "/config" },
        .{ "HOME", "/home/adrian" },
    });
    defer environment.deinit();
    const environ: std.process.Environ = .{ .block = environment.block };
    var data_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var trust_buffer: [std.fs.max_path_bytes]u8 = undefined;

    try std.testing.expectEqualStrings("/data/telar/plugins", try installBase(environ, &data_buffer));
    try std.testing.expectEqualStrings("/config/telar/trust.json", try trustPath(environ, &trust_buffer));
}

test "plugin data and trust paths fall back to HOME" {
    var environment = try TestEnvironment.init(&.{.{ "HOME", "/home/adrian" }});
    defer environment.deinit();
    const environ: std.process.Environ = .{ .block = environment.block };
    var data_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var trust_buffer: [std.fs.max_path_bytes]u8 = undefined;

    try std.testing.expectEqualStrings("/home/adrian/.local/share/telar/plugins", try installBase(environ, &data_buffer));
    try std.testing.expectEqualStrings("/home/adrian/.config/telar/trust.json", try trustPath(environ, &trust_buffer));
}

test "explicit plugin grants must be declared and unique" {
    var declared = core.plugin.CapabilitySet.initEmpty();
    declared.insert(.history_read);
    declared.insert(.notifications);
    var options: PluginOptions = .{ .command = .trust, .path = "./plugin" };
    options.capabilities[0] = .history_read;
    options.capability_count = 1;

    const granted = try grantedCapabilities(declared, &options);
    try std.testing.expect(granted.contains(.history_read));
    try std.testing.expect(!granted.contains(.notifications));

    options.capabilities[0] = .network;
    try std.testing.expectError(error.CapabilityNotDeclared, grantedCapabilities(declared, &options));

    options.capabilities[0] = .history_read;
    options.capabilities[1] = .history_read;
    options.capability_count = 2;
    try std.testing.expectError(error.DuplicateCapability, grantedCapabilities(declared, &options));
}

test "omitting plugin grants accepts every declared capability" {
    var declared = core.plugin.CapabilitySet.initEmpty();
    declared.insert(.history_read);
    declared.insert(.notifications);
    const options: PluginOptions = .{ .command = .trust, .path = "./plugin" };

    const granted = try grantedCapabilities(declared, &options);

    try std.testing.expect(granted.eql(declared));
}

test "a missing trust store loads as empty" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try temporaryPath(&temp, "missing.json", &path_buffer);

    const store = try loadStore(std.testing.io, std.testing.allocator, path);

    try std.testing.expectEqual(@as(u8, 0), store.count);
}

test "trust-store writes are private and parseable" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try temporaryPath(&temp, "config/trust.json", &path_buffer);
    const expected: core.plugin.TrustStore = .{};

    try writeStore(std.testing.io, path, &expected);

    const stat = try Io.Dir.cwd().statFile(std.testing.io, path, .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
    const loaded = try loadStore(std.testing.io, std.testing.allocator, path);
    try std.testing.expectEqual(@as(u8, 0), loaded.count);
}

test "a group-readable trust store is rejected" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try temporaryPath(&temp, "trust.json", &path_buffer);
    var file = try Io.Dir.cwd().createFile(std.testing.io, path, .{ .permissions = File.Permissions.fromMode(0o600) });
    try file.writeStreamingAll(std.testing.io, "{\"version\":1,\"grants\":[]}\n");
    file.close(std.testing.io);
    try Io.Dir.cwd().setFilePermissions(std.testing.io, path, File.Permissions.fromMode(0o640), .{ .follow_symlinks = false });

    try std.testing.expectError(error.InsecureTrustStore, loadStore(std.testing.io, std.testing.allocator, path));
}
