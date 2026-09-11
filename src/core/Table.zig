const types = @import("schema/types.zig");
const AgentManifest = @import("AgentManifest.zig");
const agent_manifest = @import("agent_manifest.zig");
const std = @import("std");
const Signal = @import("Signal.zig");
const Table = @This();

items: [types.max_agent_manifests]AgentManifest = undefined,
count: u8 = 0,

/// Registers one agent. Built-in names return their existing manifest so
/// configuration can extend the phrases; new names receive the next
/// custom provider index.
///
/// ```zig
/// const gemini = try table.add("gemini");
/// try gemini.process_names.append("gemini");
/// ```
pub fn add(table: *Table, name: []const u8) agent_manifest.AddError!*AgentManifest {
    if (!agent_manifest.validName(name)) {
        return error.InvalidName;
    }
    if (table.findByName(name)) |existing| {
        if (agent_manifest.isBuiltinProvider(existing.provider)) {
            return existing;
        }
        return error.DuplicateName;
    }
    if (table.count == types.max_agent_manifests) {
        return error.TooManyAgents;
    }

    const provider: types.AgentProvider = agent_manifest.builtinProvider(name) orelse
        @enumFromInt(types.first_custom_agent_provider + table.customCount());
    const manifest = &table.items[table.count];
    manifest.* = .{ .provider = provider };
    @memcpy(manifest.name[0..name.len], name);
    manifest.name_len = @intCast(name.len);
    table.count += 1;
    return manifest;
}

pub fn slice(table: *const Table) []const AgentManifest {
    return table.items[0..table.count];
}

pub fn find(table: *const Table, provider: types.AgentProvider) ?*const AgentManifest {
    for (table.slice()) |*manifest| {
        if (manifest.provider == provider) {
            return manifest;
        }
    }
    return null;
}

pub fn findByName(table: *Table, name: []const u8) ?*AgentManifest {
    for (table.items[0..table.count]) |*manifest| {
        if (std.mem.eql(u8, manifest.nameSlice(), name)) {
            return manifest;
        }
    }
    return null;
}

/// Display name for a provider index; unknown indexes read as "unknown".
///
/// ```zig
/// const name = table.providerName(entry.provider);
/// ```
pub fn providerName(table: *const Table, provider: types.AgentProvider) []const u8 {
    const manifest = table.find(provider) orelse return "unknown";
    return manifest.nameSlice();
}

/// Human label for a provider index; unknown indexes read as "Agent".
///
/// ```zig
/// const label = table.displayName(entry.provider);
/// ```
pub fn displayName(table: *const Table, provider: types.AgentProvider) []const u8 {
    const manifest = table.find(provider) orelse return agent_manifest.generic_display_name;
    return manifest.displayName();
}

/// Session title shown before an agent has a real one.
///
/// ```zig
/// var buffer: [max_placeholder_bytes]u8 = undefined;
/// const title = table.placeholderTitle(entry.provider, &buffer);
/// ```
pub fn placeholderTitle(table: *const Table, provider: types.AgentProvider, buffer: *[types.max_agent_session_title_bytes]u8) []const u8 {
    const manifest = table.find(provider) orelse return agent_manifest.generic_placeholder;
    return manifest.placeholderTitle(buffer);
}

/// Configured sidebar glyph; empty when the client should pick artwork.
///
/// ```zig
/// const glyph = table.icon(entry.provider);
/// ```
pub fn icon(table: *const Table, provider: types.AgentProvider) []const u8 {
    const manifest = table.find(provider) orelse return "";
    return manifest.iconSlice();
}

/// How the agent's prompt identifies pasted images.
///
/// ```zig
/// if (table.attachments(entry.provider) == .none) hideImageShelf();
/// ```
pub fn attachments(table: *const Table, provider: types.AgentProvider) types.AgentAttachmentMarkers {
    const manifest = table.find(provider) orelse return .none;
    return manifest.attachments;
}

/// Returns the object field holding a command for one provider tool.
///
/// ```zig
/// const field = table.commandField(.claude, "Bash") orelse return;
/// ```
pub fn commandField(table: *const Table, provider: types.AgentProvider, tool: []const u8) ?[]const u8 {
    const manifest = table.find(provider) orelse return null;
    return manifest.command_tools.commandField(tool);
}

/// Reports whether the agent's manifest proves readiness by itself, so a
/// generic screen scan must not override its stream signal.
///
/// ```zig
/// if (!table.declaresReadyPrompt(signal.provider)) mergeScreenScan();
/// ```
pub fn declaresReadyPrompt(table: *const Table, provider: types.AgentProvider) bool {
    const manifest = table.find(provider) orelse return false;
    return manifest.ready_prompt.count != 0;
}

/// Applies the screen heuristics to one plain-text sample. Blocked
/// outranks working; a prompt outranks identity alone.
///
/// ```zig
/// const signal = table.detect(sample) orelse return;
/// ```
pub fn detect(table: *const Table, text: []const u8) ?Signal {
    for (table.slice()) |*manifest| {
        if (manifest.blocked.matches(text)) {
            return .{ .provider = table.inferProvider(text), .status = .blocked, .confidence = 88 };
        }
    }

    for (table.slice()) |*manifest| {
        if (manifest.working.matches(text)) {
            return .{ .provider = table.inferProvider(text), .status = .working, .confidence = 78 };
        }
    }

    for (table.slice()) |*manifest| {
        if (manifest.ready_prompt.matches(text)) {
            return .{
                .provider = manifest.provider,
                .status = .ready,
                .confidence = 94,
                .identity_confirmed = true,
                .ready_confirmed = true,
            };
        }
    }

    for (table.slice()) |*manifest| {
        if (manifest.identity.matches(text)) {
            return .{
                .provider = manifest.provider,
                .status = .ready,
                .confidence = 90,
                .identity_confirmed = true,
            };
        }
    }

    return null;
}

/// Identifies an agent from an executable name, ignoring platform
/// launcher suffixes.
///
/// ```zig
/// const provider = table.providerFromExecutable("claude.exe") orelse return;
/// ```
pub fn providerFromExecutable(table: *const Table, basename: []const u8) ?types.AgentProvider {
    for (table.slice()) |*manifest| {
        for (0..manifest.process_names.count) |index| {
            if (agent_manifest.equalExecutableName(basename, manifest.process_names.get(index))) {
                return manifest.provider;
            }
        }
    }
    return null;
}

/// Identifies an agent from a path fragment of its entry point.
///
/// ```zig
/// const provider = table.providerFromPath(argument) orelse return;
/// ```
pub fn providerFromPath(table: *const Table, path: []const u8) ?types.AgentProvider {
    for (table.slice()) |*manifest| {
        if (manifest.process_paths.matches(path)) {
            return manifest.provider;
        }
    }
    return null;
}

fn inferProvider(table: *const Table, text: []const u8) types.AgentProvider {
    for (table.slice()) |*manifest| {
        if (manifest.brand.matches(text)) {
            return manifest.provider;
        }
    }
    return .unknown;
}

fn customCount(table: *const Table) u8 {
    var count: u8 = 0;
    for (table.slice()) |*manifest| {
        if (@intFromEnum(manifest.provider) >= types.first_custom_agent_provider) {
            count += 1;
        }
    }
    return count;
}
