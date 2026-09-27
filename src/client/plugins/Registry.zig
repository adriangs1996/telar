const core = @import("telar-core");
const data = @import("model");
const Package = @import("Package.zig");
const LoadContext = @import("LoadContext.zig");
const plugins = @import("plugins.zig");
const std = @import("std");
const WorkerRequest = @import("WorkerRequest.zig");
const Registry = @This();

packages: [data.config_values.max_plugins]Package = undefined,
count: u8 = 0,
grants: [core.max_grants]core.Grant = undefined,
grant_count: u8 = 0,

/// Loads enabled plugin packages without persisted capability grants.
/// For example: `const registry = try Registry.load(context, specs);`.
pub fn load(context: LoadContext, specs: []const data.PluginSpec) !Registry {
    const empty: core.TrustStore = .{};
    return loadWithTrust(context, specs, &empty);
}

/// Loads enabled plugin packages and their persisted capability grants.
/// For example: `const registry = try Registry.loadWithTrust(context, specs, trust);`.
pub fn loadWithTrust(context: LoadContext, specs: []const data.PluginSpec, trust: *const core.TrustStore) !Registry {
    var registry: Registry = .{};
    registry.grant_count = trust.count;
    for (trust.entries[0..trust.count], 0..) |entry, index|
        registry.grants[index] = entry.grant;
    for (specs) |*spec| {
        if (!spec.enabled) {
            continue;
        }
        if (registry.count == data.config_values.max_plugins) {
            return error.TooManyPlugins;
        }
        const package = try plugins.loadPackage(context, spec.path());
        for (registry.packages[0..registry.count]) |*existing| {
            if (std.mem.eql(u8, existing.manifest.id(), package.manifest.id())) {
                return error.DuplicatePluginId;
            }
            if (core.stableId(existing.manifest.id()) == core.stableId(package.manifest.id())) {
                return error.PluginIdHashCollision;
            }
        }
        registry.packages[registry.count] = package;
        registry.count += 1;
    }
    return registry;
}

pub fn resolve(self: *const Registry, requested: data.PluginAction) !Invocation {
    for (self.packages[0..self.count], 0..) |*package, package_index| {
        if (core.stableId(package.manifest.id()) != requested.plugin) {
            continue;
        }
        for (package.manifest.actions[0..package.manifest.action_count], 0..) |*name, action_index| {
            if (core.stableId(name.slice()) == requested.action) {
                return .{
                    .package_index = @intCast(package_index),
                    .action_index = @intCast(action_index),
                    .plugin_id = requested.plugin,
                    .action_id = requested.action,
                };
            }
        }
        return error.UnknownPluginAction;
    }
    return error.PluginNotConfigured;
}

pub fn validateConfiguredActions(self: *const Registry, bindings: []const data.config_values.ConfiguredBinding) !void {
    for (bindings) |binding| switch (binding.action) {
        .plugin => |requested| _ = try self.resolve(requested),
        else => {},
    };
}

pub fn workerRequest(self: *const Registry, invocation: Invocation, context: data.CallbackContext) !WorkerRequest {
    if (invocation.package_index >= self.count) {
        return error.PluginNotConfigured;
    }
    const package = &self.packages[invocation.package_index];
    if (invocation.action_index >= package.manifest.action_count) {
        return error.UnknownPluginAction;
    }
    const action_name = package.manifest.actions[invocation.action_index].slice();
    var request: WorkerRequest = .{
        .package_index = invocation.package_index,
        .plugin_id = core.stableId(package.manifest.id()),
        .digest = package.digest,
        .package = package.*,
        .action_len = @intCast(action_name.len),
        .context = context,
    };
    @memcpy(request.action_bytes[0..action_name.len], action_name);
    return request;
}

pub fn authorize(self: *const Registry, package_index: u8, capability: core.Capability) !void {
    if (package_index >= self.count) {
        return error.PluginNotConfigured;
    }
    const package = &self.packages[package_index];
    if (!package.manifest.capabilities.contains(capability)) {
        return error.CapabilityNotDeclared;
    }
    for (self.grants[0..self.grant_count]) |grant| {
        if (grant.allows(.{ .id = package.manifest.id(), .digest = package.digest }, capability)) {
            return;
        }
    }

    return error.CapabilityNotGranted;
}

/// Authorizes a worker batch against its immutable package identity.
/// For example: `try registry.authorizeBatch(.{ .package_index = index, .plugin_id = id, .digest = digest, .batch = batch });`.
pub fn authorizeBatch(self: *const Registry, authorization: BatchAuthorization) !void {
    if (authorization.package_index >= self.count) {
        return error.PluginNotConfigured;
    }
    const package = &self.packages[authorization.package_index];
    if (core.stableId(package.manifest.id()) != authorization.plugin_id or
        !std.mem.eql(u8, &package.digest, &authorization.digest))
    {
        return error.StalePluginWorker;
    }
    for (authorization.batch.slice()) |effect| {
        const capability: ?core.Capability = switch (effect) {
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
            .path_picker,
            .suggest_command,
            => null,
            .notification => .notifications,
            .scroll_pane, .lua_callback, .lua_expr, .plugin, .open_panel, .close_panel, .refresh_panel, .select_machine_offset, .machine_picker => return error.InvalidPluginEffect,
        };
        if (capability) |required| {
            try self.authorize(authorization.package_index, required);
        }
    }
}

/// Hashes every configured package path and readable file for reload detection.
/// For example: `const fingerprint = registry.watchFingerprint(gpa, io);`.
pub fn watchFingerprint(self: *const Registry, gpa: std.mem.Allocator, io: std.Io) u64 {
    var hasher = std.hash.Wyhash.init(0x74656c61722d706c);
    for (self.packages[0..self.count]) |*package|
        plugins.updatePackageFingerprint(gpa, io, .{ .hasher = &hasher, .root = package.root() });
    return hasher.final();
}

const Invocation = struct {
    package_index: u8,
    action_index: u8,
    plugin_id: u64,
    action_id: u64,
};

const BatchAuthorization = struct {
    package_index: u8,
    plugin_id: u64,
    digest: core.Digest,
    batch: *const data.EffectBatch,
};
