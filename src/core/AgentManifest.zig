const types = @import("schema/types.zig");
const agent_manifest = @import("agent_manifest.zig");
const CommandTools = @import("CommandTools.zig");
const std = @import("std");
const Manifest = @This();

provider: types.AgentProvider,
name: [types.max_agent_provider_name_bytes]u8 = undefined,
name_len: u8 = 0,
/// Human label shown wherever the agent is named; defaults to `name`.
display_name: [types.max_agent_display_name_bytes]u8 = undefined,
display_name_len: u8 = 0,
/// Session title shown until the agent has a real one; defaults to
/// "New <display name> session".
placeholder: [types.max_agent_session_title_bytes]u8 = undefined,
placeholder_len: u8 = 0,
/// One sidebar glyph. Empty leaves the choice to the client, which has
/// artwork for the built-in agents and a generic mark for the rest.
icon: [types.max_agent_icon_bytes]u8 = undefined,
icon_len: u8 = 0,
/// How the agent's prompt identifies pasted images; `none` disables the
/// image shelf for this agent.
attachments: types.AgentAttachmentMarkers = .none,
/// Executable basenames, compared without `.exe`, `.cmd`, `.bat` or `.js`.
process_names: agent_manifest.PathList = .{},
/// Path fragments of an interpreter-launched entry point.
process_paths: agent_manifest.PathList = .{},
/// Words that attribute a generic working or blocked phrase to this agent.
brand: agent_manifest.PhraseList = .{},
/// Phrases that confirm the agent's identity on screen without proving
/// readiness.
identity: agent_manifest.PhraseList = .{},
working: agent_manifest.PhraseList = .{},
blocked: agent_manifest.PhraseList = .{},
/// Prompt text that proves the agent is idle and waiting for input.
ready_prompt: agent_manifest.PhraseList = .{},
/// Tool names whose object input contains a shell command field.
command_tools: CommandTools = .{},

pub fn nameSlice(manifest: *const Manifest) []const u8 {
    return manifest.name[0..manifest.name_len];
}

/// The label to show for this agent: the configured display name, or
/// the manifest name when none was configured.
///
/// ```zig
/// const label = manifest.displayName();
/// ```
pub fn displayName(manifest: *const Manifest) []const u8 {
    if (manifest.display_name_len != 0) {
        return manifest.display_name[0..manifest.display_name_len];
    }

    return manifest.nameSlice();
}

pub fn iconSlice(manifest: *const Manifest) []const u8 {
    return manifest.icon[0..manifest.icon_len];
}

/// Writes the session title shown before the agent has a real one.
///
/// ```zig
/// var buffer: [max_placeholder_bytes]u8 = undefined;
/// const title = manifest.placeholderTitle(&buffer);
/// ```
pub fn placeholderTitle(manifest: *const Manifest, buffer: *[types.max_agent_session_title_bytes]u8) []const u8 {
    if (manifest.placeholder_len != 0) {
        return manifest.placeholder[0..manifest.placeholder_len];
    }

    return std.fmt.bufPrint(buffer, "New {s} session", .{manifest.displayName()}) catch unreachable;
}

pub fn setDisplayName(manifest: *Manifest, text: []const u8) agent_manifest.TextError!void {
    manifest.display_name_len = try agent_manifest.copyText(&manifest.display_name, text);
}

pub fn setPlaceholder(manifest: *Manifest, text: []const u8) agent_manifest.TextError!void {
    manifest.placeholder_len = try agent_manifest.copyText(&manifest.placeholder, text);
}

pub fn setIcon(manifest: *Manifest, text: []const u8) agent_manifest.TextError!void {
    manifest.icon_len = try agent_manifest.copyText(&manifest.icon, text);
}

comptime {
    // "New " + display name + " session" must always fit the placeholder.
    std.debug.assert(4 + types.max_agent_display_name_bytes + 8 <= types.max_agent_session_title_bytes);
}
