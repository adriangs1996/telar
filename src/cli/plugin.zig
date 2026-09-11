//! Plugin inspection, installation and digest-bound trust commands.

const std = @import("std");
const PluginOptions = @import("arguments/PluginOptions.zig");
const inspectPackage_module = @import("telar-frontend").inspectPackage;
const PluginWorkerOptionsType = @import("arguments/PluginWorkerOptions.zig");
const run_module = @import("telar-frontend").run;
const TrustStoreType = @import("telar-core").TrustStore;
const Package = @import("telar-frontend").Package;
const installPackage_module = @import("telar-frontend").installPackage;
const CapabilitySetType = @import("telar-core").CapabilitySet;
const TestEnvironment = @import("TestEnvironment.zig");

/// Inspects one package and performs the requested read-only, installation or
/// trust operation without executing plugin code.
///
/// ```zig
/// try plugin.run(process_init, options);
/// ```
pub fn run(init: std.process.Init, options: PluginOptions) !void {
    const package = try inspectPackage_module(init.gpa, init.io, std.mem.span(options.path));
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
pub fn runWorker(init: std.process.Init, options: PluginWorkerOptionsType) !void {
    return run_module(init, .{
        .entry_path = std.mem.span(options.entry),
        .action_name = std.mem.span(options.action),
        .context = options.context,
    });
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
pub fn loadTrustStore(init: std.process.Init, path: []const u8) !TrustStoreType {
    return loadStore(init.io, init.gpa, path);
}

fn printInspection(io: std.Io, package: *const Package) !void {
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(io, &buffer);
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
    try installPackage_module(init.gpa, init.io, .{ .package = package, .destination = destination });

    var output_buffer: [std.fs.max_path_bytes + 64]u8 = undefined;
    const output = try std.fmt.bufPrint(&output_buffer, "telar plugin installed: {s}\n", .{destination});
    try std.Io.File.stdout().writeStreamingAll(init.io, output);
}

fn trust(init: std.process.Init, package: *const Package, options: *const PluginOptions) !void {
    const granted = try grantedCapabilities(package.manifest.capabilities, options);
    var trust_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try trustPath(init.minimal.environ, &trust_path_buffer);
    var store = try loadStore(init.io, init.gpa, path);
    try store.upsert(&package.manifest, .{ .digest = package.digest, .capabilities = granted });
    try writeStore(init.io, path, &store);
    try std.Io.File.stdout().writeStreamingAll(init.io, "telar plugin trust updated\n");
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

fn grantedCapabilities(declared: CapabilitySetType, options: *const PluginOptions) !CapabilitySetType {
    if (options.capability_count == 0) {
        return declared;
    }

    var granted = CapabilitySetType.initEmpty();
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

fn loadStore(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !TrustStoreType {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => |other| return other,
    };
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0) {
        return error.InsecureTrustStore;
    }

    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024));
    defer gpa.free(source);
    return TrustStoreType.parse(gpa, source);
}

fn writeStore(io: std.Io, path: []const u8, store: *const TrustStoreType) !void {
    const directory = std.fs.path.dirname(path) orelse return error.InvalidTrustStorePath;
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, directory, std.Io.File.Permissions.fromMode(0o700));
    try std.Io.Dir.cwd().setFilePermissions(io, directory, std.Io.File.Permissions.fromMode(0o700), .{ .follow_symlinks = false });

    var nonce: [16]u8 = undefined;
    try io.randomSecure(&nonce);
    const nonce_hex = std.fmt.bytesToHex(nonce, .lower);
    var temp_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const temp = try std.fmt.bufPrint(&temp_buffer, "{s}.tmp-{s}", .{ path, &nonce_hex });
    var committed = false;
    defer if (!committed) {
        std.Io.Dir.cwd().deleteFile(io, temp) catch {};
    };

    var file = try std.Io.Dir.cwd().createFile(io, temp, .{
        .truncate = true,
        .permissions = std.Io.File.Permissions.fromMode(0o600),
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
    try std.Io.Dir.cwd().rename(temp, std.Io.Dir.cwd(), path, io);
    committed = true;
}

fn temporaryPath(temp: *std.testing.TmpDir, name: []const u8, buffer: []u8) ![]const u8 {
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(std.testing.io, &directory_buffer);
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ directory_buffer[0..directory_len], name });
}

test "plugin data and trust paths prefer their XDG homes" {
    var environment = try TestEnvironment.init(&.{
        .{ .name = "XDG_DATA_HOME", .value = "/data" },
        .{ .name = "XDG_CONFIG_HOME", .value = "/config" },
        .{ .name = "HOME", .value = "/home/adrian" },
    });
    defer environment.deinit();
    const environ: std.process.Environ = .{ .block = environment.block };
    var data_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var trust_buffer: [std.fs.max_path_bytes]u8 = undefined;

    try std.testing.expectEqualStrings("/data/telar/plugins", try installBase(environ, &data_buffer));
    try std.testing.expectEqualStrings("/config/telar/trust.json", try trustPath(environ, &trust_buffer));
}

test "plugin data and trust paths fall back to HOME" {
    var environment = try TestEnvironment.init(&.{.{ .name = "HOME", .value = "/home/adrian" }});
    defer environment.deinit();
    const environ: std.process.Environ = .{ .block = environment.block };
    var data_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var trust_buffer: [std.fs.max_path_bytes]u8 = undefined;

    try std.testing.expectEqualStrings("/home/adrian/.local/share/telar/plugins", try installBase(environ, &data_buffer));
    try std.testing.expectEqualStrings("/home/adrian/.config/telar/trust.json", try trustPath(environ, &trust_buffer));
}

test "explicit plugin grants must be declared and unique" {
    var declared = CapabilitySetType.initEmpty();
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
    var declared = CapabilitySetType.initEmpty();
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
    const expected: TrustStoreType = .{};

    try writeStore(std.testing.io, path, &expected);

    const stat = try std.Io.Dir.cwd().statFile(std.testing.io, path, .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
    const loaded = try loadStore(std.testing.io, std.testing.allocator, path);
    try std.testing.expectEqual(@as(u8, 0), loaded.count);
}

test "a group-readable trust store is rejected" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try temporaryPath(&temp, "trust.json", &path_buffer);
    var file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .permissions = std.Io.File.Permissions.fromMode(0o600) });
    try file.writeStreamingAll(std.testing.io, "{\"version\":1,\"grants\":[]}\n");
    file.close(std.testing.io);
    try std.Io.Dir.cwd().setFilePermissions(std.testing.io, path, std.Io.File.Permissions.fromMode(0o640), .{ .follow_symlinks = false });

    try std.testing.expectError(error.InsecureTrustStore, loadStore(std.testing.io, std.testing.allocator, path));
}
