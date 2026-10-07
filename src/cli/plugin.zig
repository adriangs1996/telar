//! Plugin inspection, installation and digest-bound trust commands.

const client = @import("telar-client");
const core = @import("telar-core");
const privatefile = @import("privatefile");
const std = @import("std");
const PluginOptions = @import("arguments/PluginOptions.zig");
const PluginWorkerOptions = @import("arguments/PluginWorkerOptions.zig");

/// The largest trust store read or written, in bytes.
const trust_store_limit = 64 * 1024;

/// Inspects one package and performs the requested read-only, installation or
/// trust operation without executing plugin code.
///
/// ```zig
/// try plugin.run(process_init, options);
/// ```
pub fn run(init: std.process.Init, options: PluginOptions) !void {
    const package = try client.inspectPackage(init.gpa, init.io, std.mem.span(options.path));
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
pub fn runWorker(init: std.process.Init, options: PluginWorkerOptions) !void {
    return client.runPluginWorker(init, .{
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
    return client.config_directory.path(environ, "trust.json", buffer);
}

/// Loads a bounded trust store after verifying that its path is a private,
/// regular file. A missing file represents an empty store.
///
/// ```zig
/// const store = try plugin.loadTrustStore(process_init, path);
/// ```
pub fn loadTrustStore(init: std.process.Init, path: []const u8) !core.TrustStore {
    return loadStore(init.io, init.gpa, path);
}

fn printInspection(io: std.Io, package: *const client.Package) !void {
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

fn install(init: std.process.Init, package: *const client.Package) !void {
    var base_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const base = try installBase(init.minimal.environ, &base_buffer);
    const digest_hex = std.fmt.bytesToHex(package.digest, .lower);
    var destination_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const destination = try std.fmt.bufPrint(&destination_buffer, "{s}/{s}/{s}", .{
        base,
        package.manifest.id(),
        &digest_hex,
    });
    try client.installPackage(init.gpa, init.io, .{ .package = package, .destination = destination });

    var output_buffer: [std.fs.max_path_bytes + 64]u8 = undefined;
    const output = try std.fmt.bufPrint(&output_buffer, "telar plugin installed: {s}\n", .{destination});
    try std.Io.File.stdout().writeStreamingAll(init.io, output);
}

fn trust(init: std.process.Init, package: *const client.Package, options: *const PluginOptions) !void {
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

fn grantedCapabilities(declared: core.CapabilitySet, options: *const PluginOptions) !core.CapabilitySet {
    if (options.capability_count == 0) {
        return declared;
    }

    var granted = core.CapabilitySet.initEmpty();
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

fn loadStore(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !core.TrustStore {
    const source = privatefile.read(io, gpa, path, .limited(trust_store_limit)) catch |err| switch (err) {
        error.InsecureFile => return error.InsecureTrustStore,
        else => |other| return other,
    } orelse return .{};
    defer gpa.free(source);

    return core.TrustStore.parse(gpa, source);
}

fn writeStore(io: std.Io, path: []const u8, store: *const core.TrustStore) !void {
    var buffer: [trust_store_limit]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try store.writeJson(&writer);

    try privatefile.replace(io, path, writer.buffered());
}
