const model = @import("../config/model.zig");
const Package = @import("Package.zig");
const max_grants_module = @import("telar-core").max_grants;
const GrantType = @import("telar-core").Grant;
const LoadContext = @import("LoadContext.zig");
const PluginSpecType = @import("../config/PluginSpec.zig");
const TrustStoreType = @import("telar-core").TrustStore;
const plugins = @import("plugins.zig");
const std = @import("std");
const stableId_module = @import("telar-core").stableId;
const PluginActionType = @import("../input/PluginAction.zig");
const Invocation = @import("Invocation.zig");
const CallbackContextType = @import("../config/CallbackContext.zig");
const WorkerRequest = @import("WorkerRequest.zig");
const CapabilityType = @import("telar-core").Capability;
const BatchAuthorization = @import("BatchAuthorization.zig");
const Registry = @This();

packages: [model.max_plugins]Package = undefined,
count: u8 = 0,
grants: [max_grants_module]GrantType = undefined,
grant_count: u8 = 0,

/// Loads enabled plugin packages without persisted capability grants.
/// For example: `const registry = try Registry.load(context, specs);`.
pub fn load(context: LoadContext, specs: []const PluginSpecType) !Registry {
    const empty: TrustStoreType = .{};
    return loadWithTrust(context, specs, &empty);
}

/// Loads enabled plugin packages and their persisted capability grants.
/// For example: `const registry = try Registry.loadWithTrust(context, specs, trust);`.
pub fn loadWithTrust(context: LoadContext, specs: []const PluginSpecType, trust: *const TrustStoreType) !Registry {
    var registry: Registry = .{};
    registry.grant_count = trust.count;
    for (trust.entries[0..trust.count], 0..) |entry, index|
        registry.grants[index] = entry.grant;
    for (specs) |*spec| {
        if (!spec.enabled) {
            continue;
        }
        if (registry.count == model.max_plugins) {
            return error.TooManyPlugins;
        }
        const package = try plugins.loadPackage(context, spec.path());
        for (registry.packages[0..registry.count]) |*existing| {
            if (std.mem.eql(u8, existing.manifest.id(), package.manifest.id())) {
                return error.DuplicatePluginId;
            }
            if (stableId_module(existing.manifest.id()) == stableId_module(package.manifest.id())) {
                return error.PluginIdHashCollision;
            }
        }
        registry.packages[registry.count] = package;
        registry.count += 1;
    }
    return registry;
}

pub fn resolve(registry: *const Registry, requested: PluginActionType) !Invocation {
    for (registry.packages[0..registry.count], 0..) |*package, package_index| {
        if (stableId_module(package.manifest.id()) != requested.plugin) {
            continue;
        }
        for (package.manifest.actions[0..package.manifest.action_count], 0..) |*name, action_index| {
            if (stableId_module(name.slice()) == requested.action) {
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

pub fn validateConfiguredActions(registry: *const Registry, bindings: []const model.ConfiguredBinding) !void {
    for (bindings) |binding| switch (binding.action) {
        .plugin => |requested| _ = try registry.resolve(requested),
        else => {},
    };
}

pub fn workerRequest(registry: *const Registry, invocation: Invocation, context: CallbackContextType) !WorkerRequest {
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
        .plugin_id = stableId_module(package.manifest.id()),
        .digest = package.digest,
        .package = package.*,
        .action_len = @intCast(action_name.len),
        .context = context,
    };
    @memcpy(request.action_bytes[0..action_name.len], action_name);
    return request;
}

pub fn authorize(registry: *const Registry, package_index: u8, capability: CapabilityType) !void {
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
    if (stableId_module(package.manifest.id()) != authorization.plugin_id or
        !std.mem.eql(u8, &package.digest, &authorization.digest))
    {
        return error.StalePluginWorker;
    }
    for (authorization.batch.slice()) |effect| {
        const capability: ?CapabilityType = switch (effect) {
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
            .scroll_pane, .lua_callback, .lua_expr, .plugin, .toggle_thread_view => return error.InvalidPluginEffect,
        };
        if (capability) |required| {
            try registry.authorize(authorization.package_index, required);
        }
    }
}

/// Hashes every configured package path and readable file for reload detection.
/// For example: `const fingerprint = registry.watchFingerprint(gpa, io);`.
pub fn watchFingerprint(registry: *const Registry, gpa: std.mem.Allocator, io: std.Io) u64 {
    var hasher = std.hash.Wyhash.init(0x74656c61722d706c);
    for (registry.packages[0..registry.count]) |*package|
        plugins.updatePackageFingerprint(gpa, io, .{ .hasher = &hasher, .root = package.root() });
    return hasher.final();
}
