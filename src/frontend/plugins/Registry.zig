const Registry = @This();
const source_namespace = @import("root.zig");
const Package = @import("Package.zig");
const LoadContext = @import("LoadContext.zig");
const lua_config = @import("../config/root.zig");
const std = @import("std");
const action_mod = @import("telar-client").input.action;
const Invocation = @import("Invocation.zig");
const WorkerRequest = @import("WorkerRequest.zig");
const BatchAuthorization = @import("BatchAuthorization.zig");
packages: [source_namespace.max_packages]Package = undefined,
count: u8 = 0,
grants: [source_namespace.plugin.max_grants]source_namespace.plugin.Grant = undefined,
grant_count: u8 = 0,

/// Loads enabled plugin packages without persisted capability grants.
/// For example: `const registry = try Registry.load(context, specs);`.
pub fn load(context: LoadContext, specs: []const lua_config.PluginSpec) !Registry {
    const empty: source_namespace.plugin.TrustStore = .{};
    return loadWithTrust(context, specs, &empty);
}

/// Loads enabled plugin packages and their persisted capability grants.
/// For example: `const registry = try Registry.loadWithTrust(context, specs, trust);`.
pub fn loadWithTrust(context: LoadContext, specs: []const lua_config.PluginSpec, trust: *const source_namespace.plugin.TrustStore) !Registry {
    var registry: Registry = .{};
    registry.grant_count = trust.count;
    for (trust.entries[0..trust.count], 0..) |entry, index|
        registry.grants[index] = entry.grant;
    for (specs) |*spec| {
        if (!spec.enabled) {
            continue;
        }
        if (registry.count == source_namespace.max_packages) {
            return error.TooManyPlugins;
        }
        const package = try source_namespace.loadPackage(context, spec.path());
        for (registry.packages[0..registry.count]) |*existing| {
            if (std.mem.eql(u8, existing.manifest.id(), package.manifest.id())) {
                return error.DuplicatePluginId;
            }
            if (source_namespace.plugin.stableId(existing.manifest.id()) == source_namespace.plugin.stableId(package.manifest.id())) {
                return error.PluginIdHashCollision;
            }
        }
        registry.packages[registry.count] = package;
        registry.count += 1;
    }
    return registry;
}

pub fn resolve(registry: *const Registry, requested: action_mod.PluginAction) !Invocation {
    for (registry.packages[0..registry.count], 0..) |*package, package_index| {
        if (source_namespace.plugin.stableId(package.manifest.id()) != requested.plugin) {
            continue;
        }
        for (package.manifest.actions[0..package.manifest.action_count], 0..) |*name, action_index| {
            if (source_namespace.plugin.stableId(name.slice()) == requested.action) {
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

pub fn validateConfiguredActions(registry: *const Registry, bindings: []const lua_config.ConfiguredBinding) !void {
    for (bindings) |binding| switch (binding.action) {
        .plugin => |requested| _ = try registry.resolve(requested),
        else => {},
    };
}

pub fn workerRequest(registry: *const Registry, invocation: Invocation, context: lua_config.CallbackContext) !WorkerRequest {
    if (invocation.package_index >= registry.count) {
        return error.PluginNotConfigured;
    }
    const package = &registry.packages[invocation.package_index];
    if (invocation.action_index >= package.manifest.action_count) {
        return error.UnknownPluginAction;
    }
    const action_name = package.manifest.actions[invocation.action_index].slice();
    var request: WorkerRequest = .{
        .package_index = invocation.package_index,
        .plugin_id = source_namespace.plugin.stableId(package.manifest.id()),
        .digest = package.digest,
        .package = package.*,
        .action_len = @intCast(action_name.len),
        .context = context,
    };
    @memcpy(request.action_bytes[0..action_name.len], action_name);
    return request;
}

pub fn authorize(registry: *const Registry, package_index: u8, capability: source_namespace.plugin.Capability) !void {
    if (package_index >= registry.count) {
        return error.PluginNotConfigured;
    }
    const package = &registry.packages[package_index];
    if (!package.manifest.capabilities.contains(capability)) {
        return error.CapabilityNotDeclared;
    }
    for (registry.grants[0..registry.grant_count]) |grant| {
        if (grant.allows(.{ .id = package.manifest.id(), .digest = package.digest }, capability)) {
            return;
        }
    }

    return error.CapabilityNotGranted;
}

/// Authorizes a worker batch against its immutable package identity.
/// For example: `try registry.authorizeBatch(.{ .package_index = index, .plugin_id = id, .digest = digest, .batch = batch });`.
pub fn authorizeBatch(registry: *const Registry, authorization: BatchAuthorization) !void {
    if (authorization.package_index >= registry.count) {
        return error.PluginNotConfigured;
    }
    const package = &registry.packages[authorization.package_index];
    if (source_namespace.plugin.stableId(package.manifest.id()) != authorization.plugin_id or
        !std.mem.eql(u8, &package.digest, &authorization.digest))
    {
        return error.StalePluginWorker;
    }
    for (authorization.batch.slice()) |effect| {
        const capability: ?source_namespace.plugin.Capability = switch (effect) {
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
            .scroll_pane, .lua_callback, .lua_expr, .plugin, .toggle_agent_mode => return error.InvalidPluginEffect,
        };
        if (capability) |required| {
            try registry.authorize(authorization.package_index, required);
        }
    }
}

/// Hashes every configured package path and readable file for reload detection.
/// For example: `const fingerprint = registry.watchFingerprint(gpa, io);`.
pub fn watchFingerprint(registry: *const Registry, gpa: std.mem.Allocator, io: source_namespace.Io) u64 {
    var hasher = std.hash.Wyhash.init(0x74656c61722d706c);
    for (registry.packages[0..registry.count]) |*package|
        source_namespace.updatePackageFingerprint(gpa, io, .{ .hasher = &hasher, .root = package.root() });
    return hasher.final();
}
