const types = @import("schema/types.zig");
const AgentManifest = @import("AgentManifest.zig");
const agent_manifest = @import("agent_manifest.zig");
const std = @import("std");
const Signal = @import("Signal.zig");
const Limit = @import("Limit.zig");
const Table = @This();

/// The limit a configuration reaches when it names more agents than the
/// table holds, built-in ones included.
pub const capacity_limit = Limit.declare("config.max_agent_manifests", "agents", types.max_agent_manifests);

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
pub fn add(self: *Table, name: []const u8) agent_manifest.AddError!*AgentManifest {
    if (!agent_manifest.validName(name)) {
        return error.InvalidName;
    }
    if (self.findByName(name)) |existing| {
        if (agent_manifest.isBuiltinProvider(existing.provider)) {
            return existing;
        }
        return error.DuplicateName;
    }
    if (self.count == types.max_agent_manifests) {
        return error.TooManyAgents;
    }

    const provider: types.AgentProvider = agent_manifest.builtinProvider(name) orelse
        @enumFromInt(types.first_custom_agent_provider + self.customCount());
    const manifest = &self.items[self.count];
    manifest.* = .{ .provider = provider };
    @memcpy(manifest.name[0..name.len], name);
    manifest.name_len = @intCast(name.len);
    self.count += 1;
    return manifest;
}

pub fn slice(self: *const Table) []const AgentManifest {
    return self.items[0..self.count];
}

pub fn find(self: *const Table, provider: types.AgentProvider) ?*const AgentManifest {
    for (self.slice()) |*manifest| {
        if (manifest.provider == provider) {
            return manifest;
        }
    }
    return null;
}

pub fn findByName(self: *Table, name: []const u8) ?*AgentManifest {
    for (self.items[0..self.count]) |*manifest| {
        if (std.mem.eql(u8, manifest.nameSlice(), name)) {
            return manifest;
        }
    }
    return null;
}

/// The provider a manifest name stands for; `unknown` when no manifest has
/// that name.
///
/// ```zig
/// const provider = table.providerNamed(report.provider);
/// ```
pub fn providerNamed(self: *const Table, name: []const u8) types.AgentProvider {
    for (self.slice()) |*manifest| {
        if (std.mem.eql(u8, manifest.nameSlice(), name)) {
            return manifest.provider;
        }
    }

    return .unknown;
}

/// Display name for a provider index; unknown indexes read as "unknown".
///
/// ```zig
/// const name = table.providerName(entry.provider);
/// ```
pub fn providerName(self: *const Table, provider: types.AgentProvider) []const u8 {
    const manifest = self.find(provider) orelse return "unknown";
    return manifest.nameSlice();
}

/// Human label for a provider index; unknown indexes read as "Agent".
///
/// ```zig
/// const label = table.displayName(entry.provider);
/// ```
pub fn displayName(self: *const Table, provider: types.AgentProvider) []const u8 {
    const manifest = self.find(provider) orelse return agent_manifest.generic_display_name;
    return manifest.displayName();
}

/// Session title shown before an agent has a real one.
///
/// ```zig
/// var buffer: [max_placeholder_bytes]u8 = undefined;
/// const title = table.placeholderTitle(entry.provider, &buffer);
/// ```
pub fn placeholderTitle(self: *const Table, provider: types.AgentProvider, buffer: *[types.max_agent_session_title_bytes]u8) []const u8 {
    const manifest = self.find(provider) orelse return agent_manifest.generic_placeholder;
    return manifest.placeholderTitle(buffer);
}

/// Configured sidebar glyph; empty when the client should pick artwork.
///
/// ```zig
/// const glyph = table.icon(entry.provider);
/// ```
pub fn icon(self: *const Table, provider: types.AgentProvider) []const u8 {
    const manifest = self.find(provider) orelse return "";
    return manifest.iconSlice();
}

/// How the agent's prompt identifies pasted images.
///
/// ```zig
/// if (table.attachments(entry.provider) == .none) hideImageShelf();
/// ```
pub fn attachments(self: *const Table, provider: types.AgentProvider) types.AgentAttachmentMarkers {
    const manifest = self.find(provider) orelse return .none;
    return manifest.attachments;
}

/// The key that stops one provider's current turn.
///
/// ```zig
/// const key = table.interrupt(.claude);
/// ```
pub fn interrupt(self: *const Table, provider: types.AgentProvider) agent_manifest.InterruptKey {
    const manifest = self.find(provider) orelse return .none;
    return manifest.interrupt;
}

/// Returns the object field holding a command for one provider tool.
///
/// ```zig
/// const field = table.commandField(.claude, "Bash") orelse return;
/// ```
pub fn commandField(self: *const Table, provider: types.AgentProvider, tool: []const u8) ?[]const u8 {
    const manifest = self.find(provider) orelse return null;
    return manifest.command_tools.commandField(tool);
}

/// Reports whether the agent's manifest proves readiness by itself, so a
/// generic screen scan must not override its stream signal.
///
/// ```zig
/// if (!table.declaresReadyPrompt(signal.provider)) mergeScreenScan();
/// ```
pub fn declaresReadyPrompt(self: *const Table, provider: types.AgentProvider) bool {
    const manifest = self.find(provider) orelse return false;
    return manifest.ready_prompt.count != 0;
}

/// Applies the screen heuristics to one plain-text sample. Blocked
/// outranks working; a prompt outranks identity alone.
///
/// ```zig
/// const signal = table.detect(sample) orelse return;
/// ```
pub fn detect(self: *const Table, text: []const u8) ?Signal {
    for (self.slice()) |*manifest| {
        if (manifest.blocked.matches(text)) {
            return .{ .provider = self.inferProvider(text), .status = .blocked, .confidence = 88 };
        }
    }

    for (self.slice()) |*manifest| {
        if (manifest.working.matches(text)) {
            return .{ .provider = self.inferProvider(text), .status = .working, .confidence = 78 };
        }
    }

    for (self.slice()) |*manifest| {
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

    for (self.slice()) |*manifest| {
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
pub fn providerFromExecutable(self: *const Table, basename: []const u8) ?types.AgentProvider {
    for (self.slice()) |*manifest| {
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
pub fn providerFromPath(self: *const Table, path: []const u8) ?types.AgentProvider {
    for (self.slice()) |*manifest| {
        if (manifest.process_paths.matches(path)) {
            return manifest.provider;
        }
    }
    return null;
}

fn inferProvider(self: *const Table, text: []const u8) types.AgentProvider {
    for (self.slice()) |*manifest| {
        if (manifest.brand.matches(text)) {
            return manifest.provider;
        }
    }
    return .unknown;
}

fn customCount(self: *const Table) u8 {
    var count: u8 = 0;
    for (self.slice()) |*manifest| {
        if (@intFromEnum(manifest.provider) >= types.first_custom_agent_provider) {
            count += 1;
        }
    }
    return count;
}
