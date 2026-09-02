//! Client-side plugin registry and capability broker.
//!
//! The registry only reads data and hashes code. Plugin Lua is never loaded in
//! the client process; a resolved invocation is suitable for a separate worker.

const std = @import("std");
const core = @import("telar-core");
const action_mod = @import("../input/root.zig").action;
const lua_config = @import("../config/root.zig");
const protocol = @import("protocol.zig");

const Io = std.Io;
const plugin = core.plugin;

pub const runWorker = @import("worker.zig").run;

pub const max_packages = lua_config.max_plugins;
pub const max_package_files = 256;
pub const max_package_bytes = 16 * 1024 * 1024;

pub const Package = struct {
    manifest: plugin.Manifest,
    digest: plugin.Digest,
    root_bytes: [std.fs.max_path_bytes]u8 = undefined,
    root_len: u16,
    entry_bytes: [std.fs.max_path_bytes]u8 = undefined,
    entry_len: u16,

    pub fn root(package: *const Package) []const u8 {
        return package.root_bytes[0..package.root_len];
    }

    pub fn entryPath(package: *const Package) []const u8 {
        return package.entry_bytes[0..package.entry_len];
    }
};

pub const Registry = struct {
    packages: [max_packages]Package = undefined,
    count: u8 = 0,
    grants: [plugin.max_grants]plugin.Grant = undefined,
    grant_count: u8 = 0,

    pub fn load(
        gpa: std.mem.Allocator,
        io: Io,
        config_dir: []const u8,
        specs: []const lua_config.PluginSpec,
    ) !Registry {
        const empty: plugin.TrustStore = .{};
        return loadWithTrust(gpa, io, config_dir, specs, &empty);
    }

    pub fn loadWithTrust(
        gpa: std.mem.Allocator,
        io: Io,
        config_dir: []const u8,
        specs: []const lua_config.PluginSpec,
        trust: *const plugin.TrustStore,
    ) !Registry {
        var registry: Registry = .{};
        registry.grant_count = trust.count;
        for (trust.entries[0..trust.count], 0..) |entry, index|
            registry.grants[index] = entry.grant;
        for (specs) |*spec| {
            if (!spec.enabled) continue;
            if (registry.count == max_packages) return error.TooManyPlugins;
            const package = try loadPackage(gpa, io, config_dir, spec.path());
            for (registry.packages[0..registry.count]) |*existing| {
                if (std.mem.eql(u8, existing.manifest.id(), package.manifest.id()))
                    return error.DuplicatePluginId;
                if (plugin.stableId(existing.manifest.id()) == plugin.stableId(package.manifest.id()))
                    return error.PluginIdHashCollision;
            }
            registry.packages[registry.count] = package;
            registry.count += 1;
        }
        return registry;
    }

    pub fn resolve(
        registry: *const Registry,
        requested: action_mod.PluginAction,
    ) !Invocation {
        for (registry.packages[0..registry.count], 0..) |*package, package_index| {
            if (plugin.stableId(package.manifest.id()) != requested.plugin) continue;
            for (package.manifest.actions[0..package.manifest.action_count], 0..) |*name, action_index| {
                if (plugin.stableId(name.slice()) == requested.action)
                    return .{
                        .package_index = @intCast(package_index),
                        .action_index = @intCast(action_index),
                        .plugin_id = requested.plugin,
                        .action_id = requested.action,
                    };
            }
            return error.UnknownPluginAction;
        }
        return error.PluginNotConfigured;
    }

    pub fn validateConfiguredActions(
        registry: *const Registry,
        bindings: []const lua_config.ConfiguredBinding,
    ) !void {
        for (bindings) |binding| switch (binding.action) {
            .plugin => |requested| _ = try registry.resolve(requested),
            else => {},
        };
    }

    pub fn workerRequest(
        registry: *const Registry,
        invocation: Invocation,
        context: lua_config.CallbackContext,
    ) !WorkerRequest {
        if (invocation.package_index >= registry.count) return error.PluginNotConfigured;
        const package = &registry.packages[invocation.package_index];
        if (invocation.action_index >= package.manifest.action_count)
            return error.UnknownPluginAction;
        const action_name = package.manifest.actions[invocation.action_index].slice();
        var request: WorkerRequest = .{
            .package_index = invocation.package_index,
            .plugin_id = plugin.stableId(package.manifest.id()),
            .digest = package.digest,
            .package = package.*,
            .action_len = @intCast(action_name.len),
            .context = context,
        };
        @memcpy(request.action_bytes[0..action_name.len], action_name);
        return request;
    }

    pub fn authorize(
        registry: *const Registry,
        package_index: u8,
        capability: plugin.Capability,
    ) !void {
        if (package_index >= registry.count) return error.PluginNotConfigured;
        const package = &registry.packages[package_index];
        if (!package.manifest.capabilities.contains(capability))
            return error.CapabilityNotDeclared;
        for (registry.grants[0..registry.grant_count]) |grant|
            if (grant.allows(package.manifest.id(), package.digest, capability)) return;
        return error.CapabilityNotGranted;
    }

    pub fn authorizeBatch(
        registry: *const Registry,
        package_index: u8,
        plugin_id: u64,
        digest: plugin.Digest,
        batch: *const lua_config.EffectBatch,
    ) !void {
        if (package_index >= registry.count) return error.PluginNotConfigured;
        const package = &registry.packages[package_index];
        if (plugin.stableId(package.manifest.id()) != plugin_id or
            !std.mem.eql(u8, &package.digest, &digest))
            return error.StalePluginWorker;
        for (batch.slice()) |effect| {
            const capability: ?plugin.Capability = switch (effect) {
                .split_pane, .close_pane, .new_workspace, .rename_workspace, .new_tab, .rename_tab, .close_tab, .move_tab, .detach => .runtime_control,
                .focus_pane,
                .navigate_pane,
                .resize_pane,
                .toggle_pane_fullscreen,
                .toggle_sidebar,
                .resize_sidebar,
                .toggle_workspace_list,
                .select_workspace,
                .select_tab_offset,
                .select_tab,
                .enter_copy_mode,
                .command_tab,
                .goto_picker,
                .history_palette,
                .suggest_command,
                => null,
                .notification => .notifications,
                .lua_callback, .lua_expr, .plugin => return error.InvalidPluginEffect,
            };
            if (capability) |required| try registry.authorize(package_index, required);
        }
    }

    pub fn watchFingerprint(
        registry: *const Registry,
        gpa: std.mem.Allocator,
        io: Io,
    ) u64 {
        var hasher = std.hash.Wyhash.init(0x74656c61722d706c);
        for (registry.packages[0..registry.count]) |*package|
            updatePackageFingerprint(&hasher, gpa, io, package.root());
        return hasher.final();
    }
};

pub const Invocation = struct {
    package_index: u8,
    action_index: u8,
    plugin_id: u64,
    action_id: u64,
};

pub const WorkerRequest = struct {
    package_index: u8,
    plugin_id: u64,
    digest: plugin.Digest,
    package: Package,
    action_bytes: [plugin.max_action_bytes]u8 = undefined,
    action_len: u8,
    context: lua_config.CallbackContext,

    pub fn action(request: *const WorkerRequest) []const u8 {
        return request.action_bytes[0..request.action_len];
    }
};

pub const WorkerResult = struct {
    package_index: u8,
    plugin_id: u64,
    digest: plugin.Digest,
    batch: lua_config.EffectBatch,
};

pub fn executeWorker(
    io: Io,
    gpa: std.mem.Allocator,
    request: WorkerRequest,
) !WorkerResult {
    var nonce: [16]u8 = undefined;
    try io.randomSecure(&nonce);
    const nonce_hex = std.fmt.bytesToHex(nonce, .lower);
    var snapshot_root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const snapshot_root = try std.fmt.bufPrint(
        &snapshot_root_buffer,
        "/tmp/telar-plugin-worker-{d}-{s}",
        .{ std.c.getuid(), &nonce_hex },
    );
    try Io.Dir.cwd().createDir(io, snapshot_root, Io.File.Permissions.fromMode(0o700));
    defer Io.Dir.cwd().deleteTree(io, snapshot_root) catch {};
    var snapshot_package_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const snapshot_package = try std.fmt.bufPrint(
        &snapshot_package_buffer,
        "{s}/package",
        .{snapshot_root},
    );
    try installPackage(gpa, io, &request.package, snapshot_package);
    var entry_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const entry = try std.fmt.bufPrint(
        &entry_buffer,
        "{s}/{s}",
        .{ snapshot_package, request.package.manifest.entry() },
    );
    var executable_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const executable = executable_buffer[0..try std.process.executablePath(io, &executable_buffer)];
    var sidebar_buffer: [2]u8 = undefined;
    const sidebar = try std.fmt.bufPrint(&sidebar_buffer, "{d}", .{@intFromBool(request.context.sidebar_visible)});
    var tabs_buffer: [8]u8 = undefined;
    const tabs = try std.fmt.bufPrint(&tabs_buffer, "{d}", .{request.context.tab_count});
    var active_buffer: [8]u8 = undefined;
    const active = try std.fmt.bufPrint(&active_buffer, "{d}", .{request.context.active_tab_index});
    var panes_buffer: [8]u8 = undefined;
    const panes = try std.fmt.bufPrint(&panes_buffer, "{d}", .{request.context.pane_count});
    var pane_id_buffer: [24]u8 = undefined;
    const pane_id = try std.fmt.bufPrint(&pane_id_buffer, "{d}", .{request.context.focused_pane_id});
    const argv = [_][]const u8{
        executable,
        "plugin-worker",
        entry,
        request.action(),
        sidebar,
        tabs,
        active,
        panes,
        pane_id,
    };
    var empty_environment = std.process.Environ.Map.init(gpa);
    defer empty_environment.deinit();
    const result = try std.process.run(gpa, io, .{
        .argv = &argv,
        .cwd = .{ .path = "/" },
        .environ_map = &empty_environment,
        .stdout_limit = .limited(protocol.max_bytes),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(2) } },
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |status| if (status != 0) return error.PluginWorkerFailed,
        else => return error.PluginWorkerFailed,
    }
    return .{
        .package_index = request.package_index,
        .plugin_id = request.plugin_id,
        .digest = request.digest,
        .batch = try protocol.decode(result.stdout),
    };
}

fn loadPackage(
    gpa: std.mem.Allocator,
    io: Io,
    config_dir: []const u8,
    configured_path: []const u8,
) !Package {
    const joined = if (std.fs.path.isAbsolute(configured_path))
        try gpa.dupe(u8, configured_path)
    else
        try std.fs.path.resolve(gpa, &.{ config_dir, configured_path });
    defer gpa.free(joined);

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try Io.Dir.cwd().realPathFile(io, joined, &root_buffer);
    const root = root_buffer[0..root_len];
    var manifest_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const manifest_path = try std.fmt.bufPrint(
        &manifest_path_buffer,
        "{s}" ++ std.fs.path.sep_str ++ "plugin.json",
        .{root},
    );
    const manifest_bytes = try Io.Dir.cwd().readFileAlloc(
        io,
        manifest_path,
        gpa,
        .limited(plugin.max_manifest_bytes),
    );
    defer gpa.free(manifest_bytes);
    const manifest = try plugin.parseManifest(gpa, manifest_bytes);

    var candidate_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const candidate = try std.fmt.bufPrint(
        &candidate_buffer,
        "{s}" ++ std.fs.path.sep_str ++ "{s}",
        .{ root, manifest.entry() },
    );
    var entry_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const entry_len = try Io.Dir.cwd().realPathFile(io, candidate, &entry_buffer);
    const entry = entry_buffer[0..entry_len];
    if (!pathInside(root, entry)) return error.EntrypointEscapesPackage;
    const entry_bytes = try Io.Dir.cwd().readFileAlloc(
        io,
        entry,
        gpa,
        .limited(lua_config.max_config_bytes),
    );
    defer gpa.free(entry_bytes);

    var package: Package = .{
        .manifest = manifest,
        .digest = try digestPackage(gpa, io, root),
        .root_len = @intCast(root.len),
        .entry_len = @intCast(entry.len),
    };
    @memcpy(package.root_bytes[0..root.len], root);
    @memcpy(package.entry_bytes[0..entry.len], entry);
    return package;
}

fn digestPackage(gpa: std.mem.Allocator, io: Io, root: []const u8) !plugin.Digest {
    var directory = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer directory.close(io);
    var walker = try directory.walk(gpa);
    defer walker.deinit();
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |path| gpa.free(path);
        paths.deinit(gpa);
    }
    var entry_count: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry_count == max_package_files) return error.TooManyPluginEntries;
        entry_count += 1;
        switch (entry.kind) {
            .directory => {},
            .file => {
                const copied_path = try gpa.dupe(u8, entry.path);
                paths.append(gpa, copied_path) catch |err| {
                    gpa.free(copied_path);
                    return err;
                };
            },
            else => return error.UnsupportedPluginFile,
        }
    }
    std.sort.insertion([]u8, paths.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("telar-plugin-package-v1\x00");
    var total: usize = 0;
    var length: [8]u8 = undefined;
    for (paths.items) |path| {
        const remaining = max_package_bytes - total;
        const full_path = try std.fs.path.join(gpa, &.{ root, path });
        const bytes = Io.Dir.cwd().readFileAlloc(
            io,
            full_path,
            gpa,
            .limited(remaining),
        ) catch |err| switch (err) {
            error.StreamTooLong => {
                gpa.free(full_path);
                return error.PluginPackageTooLarge;
            },
            else => {
                gpa.free(full_path);
                return err;
            },
        };
        gpa.free(full_path);
        total += bytes.len;
        std.mem.writeInt(u64, &length, path.len, .little);
        hasher.update(&length);
        hasher.update(path);
        std.mem.writeInt(u64, &length, bytes.len, .little);
        hasher.update(&length);
        hasher.update(bytes);
        gpa.free(bytes);
    }
    return hasher.finalResult();
}

pub fn inspectPackage(
    gpa: std.mem.Allocator,
    io: Io,
    path: []const u8,
) !Package {
    return loadPackage(gpa, io, ".", path);
}

pub fn installPackage(
    gpa: std.mem.Allocator,
    io: Io,
    package: *const Package,
    destination: []const u8,
) !void {
    if (Io.Dir.cwd().statFile(io, destination, .{ .follow_symlinks = false })) |stat| {
        if (stat.kind != .directory) return error.PluginInstallTargetExists;
        const installed = try inspectPackage(gpa, io, destination);
        if (!std.mem.eql(u8, &installed.digest, &package.digest))
            return error.PluginInstallTargetMismatch;
        return;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const parent = std.fs.path.dirname(destination) orelse return error.InvalidPluginInstallPath;
    _ = try Io.Dir.cwd().createDirPathStatus(
        io,
        parent,
        Io.File.Permissions.fromMode(0o700),
    );
    var nonce: [16]u8 = undefined;
    try io.randomSecure(&nonce);
    const nonce_hex = std.fmt.bytesToHex(nonce, .lower);
    var temp_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const temp = try std.fmt.bufPrint(
        &temp_buffer,
        "{s}.tmp-{s}",
        .{ destination, &nonce_hex },
    );
    try Io.Dir.cwd().createDir(io, temp, Io.File.Permissions.fromMode(0o700));
    var committed = false;
    defer if (!committed) Io.Dir.cwd().deleteTree(io, temp) catch {};

    var source = try Io.Dir.cwd().openDir(io, package.root(), .{ .iterate = true });
    defer source.close(io);
    var walker = try source.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        const target = try std.fs.path.join(gpa, &.{ temp, entry.path });
        defer gpa.free(target);
        switch (entry.kind) {
            .directory => try Io.Dir.cwd().createDir(
                io,
                target,
                Io.File.Permissions.fromMode(0o700),
            ),
            .file => try Io.Dir.copyFile(
                source,
                entry.path,
                Io.Dir.cwd(),
                target,
                io,
                .{
                    .permissions = Io.File.Permissions.fromMode(0o600),
                    .make_path = true,
                    .replace = false,
                },
            ),
            else => return error.UnsupportedPluginFile,
        }
    }
    const copied = try inspectPackage(gpa, io, temp);
    if (!std.mem.eql(u8, copied.manifest.id(), package.manifest.id()) or
        !std.mem.eql(u8, &copied.digest, &package.digest))
        return error.PluginChangedDuringInstall;
    try Io.Dir.cwd().rename(temp, Io.Dir.cwd(), destination, io);
    committed = true;
}

fn pathInside(root: []const u8, candidate: []const u8) bool {
    if (!std.mem.startsWith(u8, candidate, root)) return false;
    return candidate.len == root.len or
        (candidate.len > root.len and candidate[root.len] == std.fs.path.sep);
}

fn updatePackageFingerprint(
    hasher: *std.hash.Wyhash,
    gpa: std.mem.Allocator,
    io: Io,
    root: []const u8,
) void {
    hasher.update(root);
    var directory = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch {
        hasher.update("\x00unreadable");
        return;
    };
    defer directory.close(io);
    var walker = directory.walk(gpa) catch {
        hasher.update("\x00out-of-memory");
        return;
    };
    defer walker.deinit();
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |path| gpa.free(path);
        paths.deinit(gpa);
    }
    while (walker.next(io) catch {
        hasher.update("\x00walk-error");
        return;
    }) |entry| {
        if (paths.items.len == max_package_files) {
            hasher.update("\x00too-many-files");
            return;
        }
        const copied_path = gpa.dupe(u8, entry.path) catch {
            hasher.update("\x00out-of-memory");
            return;
        };
        paths.append(gpa, copied_path) catch {
            gpa.free(copied_path);
            hasher.update("\x00out-of-memory");
            return;
        };
    }
    std.sort.insertion([]u8, paths.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    for (paths.items) |path| {
        hasher.update(path);
        const full_path = std.fs.path.join(gpa, &.{ root, path }) catch {
            hasher.update("\x00out-of-memory");
            return;
        };
        const stat = Io.Dir.cwd().statFile(io, full_path, .{ .follow_symlinks = false }) catch {
            gpa.free(full_path);
            hasher.update("\x00missing");
            continue;
        };
        gpa.free(full_path);
        hasher.update(std.mem.asBytes(&stat.kind));
        hasher.update(std.mem.asBytes(&stat.size));
        hasher.update(std.mem.asBytes(&stat.mtime.nanoseconds));
    }
}

test "path containment rejects sibling prefix tricks" {
    try std.testing.expect(pathInside("/tmp/plugin", "/tmp/plugin/main.lua"));
    try std.testing.expect(!pathInside("/tmp/plugin", "/tmp/plugin-evil/main.lua"));
}

test "privileged plugin effects require a digest-bound capability grant" {
    const manifest_source =
        \\{
        \\  "api_version": 1,
        \\  "id": "dev.telar.test",
        \\  "version": "1.0.0",
        \\  "entry": "plugin.lua",
        \\  "source": { "url": "local:test", "revision": "abc123" },
        \\  "actions": ["close"],
        \\  "capabilities": ["runtime.control"]
        \\}
    ;
    const manifest = try plugin.parseManifest(std.testing.allocator, manifest_source);
    const digest: plugin.Digest = @splat(7);
    var registry: Registry = .{};
    registry.packages[0] = .{
        .manifest = manifest,
        .digest = digest,
        .root_len = 0,
        .entry_len = 0,
    };
    registry.count = 1;
    var batch: lua_config.EffectBatch = .{};
    batch.items[0] = .close_pane;
    batch.len = 1;

    try std.testing.expectError(
        error.CapabilityNotGranted,
        registry.authorizeBatch(0, plugin.stableId(manifest.id()), digest, &batch),
    );
    registry.grants[0] = .{
        .plugin_hash = plugin.stableId(manifest.id()),
        .digest = digest,
        .capabilities = plugin.CapabilitySet.initOne(.runtime_control),
    };
    registry.grant_count = 1;
    try registry.authorizeBatch(0, plugin.stableId(manifest.id()), digest, &batch);

    const stale_digest: plugin.Digest = @splat(8);
    try std.testing.expectError(
        error.StalePluginWorker,
        registry.authorizeBatch(0, plugin.stableId(manifest.id()), stale_digest, &batch),
    );
}

test "plugin notification effects require the notifications capability" {
    const manifest = try plugin.parseManifest(
        std.testing.allocator,
        "{\"api_version\":1,\"id\":\"dev.telar.notify\",\"version\":\"1\",\"entry\":\"plugin.lua\",\"source\":{\"url\":\"local:test\",\"revision\":\"one\"},\"actions\":[\"notify\"],\"capabilities\":[\"notifications\"]}",
    );
    const digest: plugin.Digest = @splat(5);
    var registry: Registry = .{};
    registry.packages[0] = .{
        .manifest = manifest,
        .digest = digest,
        .root_len = 0,
        .entry_len = 0,
    };
    registry.count = 1;
    var batch: lua_config.EffectBatch = .{};
    batch.items[0] = .{ .notification = try action_mod.Notification.init(
        .info,
        2000,
        .none,
        "Ready",
        "",
    ) };
    batch.len = 1;

    try std.testing.expectError(
        error.CapabilityNotGranted,
        registry.authorizeBatch(0, plugin.stableId(manifest.id()), digest, &batch),
    );
    registry.grants[0] = .{
        .plugin_hash = plugin.stableId(manifest.id()),
        .digest = digest,
        .capabilities = plugin.CapabilitySet.initOne(.notifications),
    };
    registry.grant_count = 1;
    try registry.authorizeBatch(0, plugin.stableId(manifest.id()), digest, &batch);
}

test "configured plugin actions resolve before the keymap becomes active" {
    const manifest = try plugin.parseManifest(
        std.testing.allocator,
        "{\"api_version\":1,\"id\":\"dev.telar.binding-test\",\"version\":\"1\",\"entry\":\"plugin.lua\",\"source\":{\"url\":\"local:test\",\"revision\":\"one\"},\"actions\":[\"known\"]}",
    );
    var registry: Registry = .{};
    registry.packages[0] = .{
        .manifest = manifest,
        .digest = @splat(1),
        .root_len = 0,
        .entry_len = 0,
    };
    registry.count = 1;
    const binding = try lua_config.ConfiguredBinding.parse(
        &.{"escape"},
        .{ .plugin = .{
            .plugin = plugin.stableId(manifest.id()),
            .action = plugin.stableId("missing"),
        } },
    );
    try std.testing.expectError(
        error.UnknownPluginAction,
        registry.validateConfiguredActions(&.{binding}),
    );
}

test "installation copies and revalidates the exact inspected package" {
    const io = std.testing.io;
    var source_temp = std.testing.tmpDir(.{});
    defer source_temp.cleanup();
    var destination_temp = std.testing.tmpDir(.{});
    defer destination_temp.cleanup();
    {
        var manifest = try source_temp.dir.createFile(io, "plugin.json", .{});
        defer manifest.close(io);
        try manifest.writeStreamingAll(
            io,
            "{\"api_version\":1,\"id\":\"dev.telar.install-test\",\"version\":\"1\",\"entry\":\"plugin.lua\",\"source\":{\"url\":\"local:test\",\"revision\":\"one\"},\"actions\":[\"run\"]}",
        );
    }
    {
        var entry = try source_temp.dir.createFile(io, "plugin.lua", .{});
        defer entry.close(io);
        try entry.writeStreamingAll(io, "return { actions = { run = function() return {} end } }");
    }
    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_len = try source_temp.dir.realPath(io, &source_buffer);
    const package = try inspectPackage(
        std.testing.allocator,
        io,
        source_buffer[0..source_len],
    );
    var destination_directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const destination_directory_len = try destination_temp.dir.realPath(io, &destination_directory_buffer);
    var destination_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const destination = try std.fmt.bufPrint(
        &destination_buffer,
        "{s}/installed",
        .{destination_directory_buffer[0..destination_directory_len]},
    );
    try installPackage(std.testing.allocator, io, &package, destination);
    const installed = try inspectPackage(std.testing.allocator, io, destination);
    try std.testing.expectEqualSlices(u8, &package.digest, &installed.digest);

    {
        var entry = try source_temp.dir.createFile(io, "plugin.lua", .{ .truncate = true });
        defer entry.close(io);
        try entry.writeStreamingAll(io, "return { actions = {} }");
    }
    var changed_destination_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const changed_destination = try std.fmt.bufPrint(
        &changed_destination_buffer,
        "{s}/changed",
        .{destination_directory_buffer[0..destination_directory_len]},
    );
    try std.testing.expectError(
        error.PluginChangedDuringInstall,
        installPackage(std.testing.allocator, io, &package, changed_destination),
    );
}
