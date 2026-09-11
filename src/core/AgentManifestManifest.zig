const Manifest = @This();
const source_namespace = @import("agent_manifest.zig");
const CommandTools = @import("CommandTools.zig");
const std = @import("std");
provider: source_namespace.AgentProvider,
name: [source_namespace.max_name_bytes]u8 = undefined,
name_len: u8 = 0,
/// Human label shown wherever the agent is named; defaults to `name`.
display_name: [source_namespace.max_display_name_bytes]u8 = undefined,
display_name_len: u8 = 0,
/// Session title shown until the agent has a real one; defaults to
/// "New <display name> session".
placeholder: [source_namespace.max_placeholder_bytes]u8 = undefined,
placeholder_len: u8 = 0,
/// One sidebar glyph. Empty leaves the choice to the client, which has
/// artwork for the built-in agents and a generic mark for the rest.
icon: [source_namespace.max_icon_bytes]u8 = undefined,
icon_len: u8 = 0,
/// How the agent's prompt identifies pasted images; `none` disables the
/// image shelf for this agent.
attachments: source_namespace.AttachmentMarkers = .none,
/// Executable basenames, compared without `.exe`, `.cmd`, `.bat` or `.js`.
process_names: source_namespace.PathList = .{},
/// Path fragments of an interpreter-launched entry point.
process_paths: source_namespace.PathList = .{},
/// Words that attribute a generic working or blocked phrase to this agent.
brand: source_namespace.PhraseList = .{},
/// Phrases that confirm the agent's identity on screen without proving
/// readiness.
identity: source_namespace.PhraseList = .{},
working: source_namespace.PhraseList = .{},
blocked: source_namespace.PhraseList = .{},
/// Prompt text that proves the agent is idle and waiting for input.
ready_prompt: source_namespace.PhraseList = .{},
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
pub fn placeholderTitle(manifest: *const Manifest, buffer: *[source_namespace.max_placeholder_bytes]u8) []const u8 {
    if (manifest.placeholder_len != 0) {
        return manifest.placeholder[0..manifest.placeholder_len];
    }

    return std.fmt.bufPrint(buffer, "New {s} session", .{manifest.displayName()}) catch unreachable;
}

pub fn setDisplayName(manifest: *Manifest, text: []const u8) source_namespace.TextError!void {
    manifest.display_name_len = try source_namespace.copyText(&manifest.display_name, text);
}

pub fn setPlaceholder(manifest: *Manifest, text: []const u8) source_namespace.TextError!void {
    manifest.placeholder_len = try source_namespace.copyText(&manifest.placeholder, text);
}

pub fn setIcon(manifest: *Manifest, text: []const u8) source_namespace.TextError!void {
    manifest.icon_len = try source_namespace.copyText(&manifest.icon, text);
}

comptime {
    // "New " + display name + " session" must always fit the placeholder.
    std.debug.assert(4 + source_namespace.max_display_name_bytes + 8 <= source_namespace.max_placeholder_bytes);
}
