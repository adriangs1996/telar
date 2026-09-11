//! Data-driven agent identification shared by the runtime and the config
//! loader. A manifest names one agent CLI and the bounded phrases that
//! identify its process and its visible states, so adding an agent needs
//! configuration rather than a rebuild.

const GenericBoundedList = @import("GenericBoundedList.zig").Type;
const types = @import("schema/types.zig");
const std = @import("std");
const Table = @import("Table.zig");

pub const max_phrase_bytes = 48;
pub const max_phrases = 8;
pub const max_path_bytes = 64;
pub const max_paths = 4;
pub const max_command_tools = 8;
pub const max_tool_name_bytes = 64;
pub const max_command_field_bytes = 32;

/// Labels for an agent the table does not know. Clients and the runtime use
/// the same words so an unknown agent reads identically everywhere.
pub const generic_display_name = "Agent";
pub const generic_placeholder = "New agent session";

pub const Status = enum { working, blocked, ready };

pub const ListError = error{ TooManyEntries, EntryTooLong, EmptyEntry };

pub const PhraseList = GenericBoundedList(max_phrases, max_phrase_bytes);
pub const PathList = GenericBoundedList(max_paths, max_path_bytes);

pub const TextError = error{ EmptyText, TextTooLong };

pub fn copyText(storage: []u8, text: []const u8) TextError!u8 {
    if (text.len == 0) {
        return error.EmptyText;
    }
    if (text.len > storage.len) {
        return error.TextTooLong;
    }
    @memcpy(storage[0..text.len], text);
    return @intCast(text.len);
}

pub const AddError = error{ TooManyAgents, InvalidName, DuplicateName };

/// Reports whether a provider ships with Telar. Only built-in providers may
/// carry a session resume command and keep their index across configurations.
///
/// ```zig
/// if (isBuiltinProvider(manifest.provider)) allowResume();
/// ```
pub fn isBuiltinProvider(provider: types.AgentProvider) bool {
    return switch (provider) {
        .claude, .codex, .pi => true,
        else => false,
    };
}

pub fn builtinProvider(name: []const u8) ?types.AgentProvider {
    if (std.mem.eql(u8, name, "claude")) {
        return .claude;
    }
    if (std.mem.eql(u8, name, "codex")) {
        return .codex;
    }
    if (std.mem.eql(u8, name, "pi")) {
        return .pi;
    }
    return null;
}

/// The agents Telar knows without configuration. Configuration may extend
/// their phrase lists under the same names.
pub const builtin_table: Table = buildBuiltin();

fn buildBuiltin() Table {
    @setEvalBranchQuota(20_000);
    var table: Table = .{};
    const shared_blocked = [_][]const u8{
        "press enter to confirm",
        "enter to submit answer",
        "enter to select",
        "allow command?",
        "[y/n]",
        "do you want to proceed?",
        "waiting for permission",
        "yes, and don't ask again",
    };
    const shared_working = [_][]const u8{
        "esc to interrupt",
        "working (",
        "waiting for background agents",
        "tasks still running",
        "background shells",
    };

    const claude = table.add("claude") catch unreachable;
    claude.setDisplayName("Claude Code") catch unreachable;
    claude.attachments = .stable_number;
    for ([_][]const u8{ "claude", "claude-code" }) |name| claude.process_names.append(name) catch unreachable;
    for ([_][]const u8{ "/@anthropic-ai/claude-code/", "\\@anthropic-ai\\claude-code\\" }) |path| claude.process_paths.append(path) catch unreachable;
    claude.brand.append("claude") catch unreachable;
    claude.identity.append("claude code") catch unreachable;
    claude.command_tools.append("Bash", "command") catch unreachable;
    for (shared_blocked) |phrase| claude.blocked.append(phrase) catch unreachable;
    for (shared_working) |phrase| claude.working.append(phrase) catch unreachable;

    const codex = table.add("codex") catch unreachable;
    codex.setDisplayName("Codex") catch unreachable;
    codex.attachments = .ordered;
    codex.process_names.append("codex") catch unreachable;
    for ([_][]const u8{ "/@openai/codex/", "\\@openai\\codex\\" }) |path| codex.process_paths.append(path) catch unreachable;
    codex.brand.append("codex") catch unreachable;
    codex.ready_prompt.append("ask codex to do anything") catch unreachable;
    codex.command_tools.append("Bash", "command") catch unreachable;
    codex.command_tools.append("exec_command", "cmd") catch unreachable;
    codex.command_tools.append("shell", "command") catch unreachable;

    // Pi launches as `node .../pi-coding-agent/dist/bundle/cli.js`, so its
    // entry-point path is the reliable identity; the package moved from the
    // author's scope to the company's in 2026. Pi shows no permission prompts
    // and no fixed status phrases, so it carries no screen heuristics and no
    // brand word: "pi" would match "api" or "pipe" in any pane. Its state
    // comes from process detection, the proxy and its own lifecycle reports.
    const pi = table.add("pi") catch unreachable;
    pi.setDisplayName("Pi") catch unreachable;
    pi.attachments = .pasted_path;
    pi.process_names.append("pi") catch unreachable;
    pi.command_tools.append("bash", "command") catch unreachable;
    for ([_][]const u8{
        "/@earendil-works/pi-coding-agent/",
        "\\@earendil-works\\pi-coding-agent\\",
        "/@mariozechner/pi-coding-agent/",
        "\\@mariozechner\\pi-coding-agent\\",
    }) |path| pi.process_paths.append(path) catch unreachable;

    return table;
}

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > types.max_agent_provider_name_bytes) {
        return false;
    }
    for (name) |byte| {
        const ok = std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.';
        if (!ok or std.ascii.isUpper(byte)) {
            return false;
        }
    }
    return true;
}

/// Compares an executable basename with a manifest name, ignoring a trailing
/// `.exe`, `.cmd`, `.bat` or `.js`.
pub fn equalExecutableName(actual: []const u8, expected: []const u8) bool {
    var end = actual.len;
    for ([_][]const u8{ ".exe", ".cmd", ".bat", ".js" }) |suffix| {
        if (endsWithAsciiInsensitive(actual[0..end], suffix)) {
            end -= suffix.len;
            break;
        }
    }
    return std.ascii.eqlIgnoreCase(actual[0..end], expected);
}

pub fn containsAsciiInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) {
        return false;
    }
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) {
            return true;
        }
    }
    return false;
}

fn endsWithAsciiInsensitive(haystack: []const u8, suffix: []const u8) bool {
    if (suffix.len > haystack.len) {
        return false;
    }
    return std.ascii.eqlIgnoreCase(haystack[haystack.len - suffix.len ..], suffix);
}

test "built-in table reproduces the historical Claude and Codex heuristics" {
    const table = &builtin_table;

    const blocked = table.detect("Allow command? [y/n] claude").?;
    try std.testing.expectEqual(Status.blocked, blocked.status);
    try std.testing.expectEqual(types.AgentProvider.claude, blocked.provider);

    const working = table.detect("thinking... esc to interrupt").?;
    try std.testing.expectEqual(Status.working, working.status);
    try std.testing.expectEqual(types.AgentProvider.unknown, working.provider);

    const codex = table.detect("Ask Codex to do anything").?;
    try std.testing.expectEqual(Status.ready, codex.status);
    try std.testing.expectEqual(types.AgentProvider.codex, codex.provider);
    try std.testing.expect(codex.ready_confirmed);

    const claude = table.detect("Welcome to Claude Code").?;
    try std.testing.expectEqual(types.AgentProvider.claude, claude.provider);
    try std.testing.expect(claude.identity_confirmed);
    try std.testing.expect(!claude.ready_confirmed);

    try std.testing.expect(table.detect("$ ls") == null);
    try std.testing.expectEqual(types.AgentProvider.claude, table.providerFromExecutable("claude.exe").?);
    try std.testing.expectEqual(types.AgentProvider.codex, table.providerFromPath("/usr/lib/node_modules/@openai/codex/bin/codex.js").?);
    try std.testing.expectEqualStrings("codex", table.providerName(.codex));
    try std.testing.expectEqualStrings("unknown", table.providerName(.unknown));
}

test "built-in Pi is identified by its process and entry point only" {
    const table = &builtin_table;

    try std.testing.expectEqual(types.AgentProvider.pi, table.providerFromExecutable("pi").?);
    try std.testing.expectEqual(types.AgentProvider.pi, table.providerFromPath("/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js").?);
    try std.testing.expectEqual(types.AgentProvider.pi, table.providerFromPath("/usr/lib/node_modules/@mariozechner/pi-coding-agent/dist/cli.js").?);
    try std.testing.expectEqualStrings("pi", table.providerName(.pi));
    try std.testing.expect(isBuiltinProvider(.pi));
    try std.testing.expect(!isBuiltinProvider(@enumFromInt(types.first_custom_agent_provider)));

    // No brand word: a generic blocked phrase next to "api" stays unattributed.
    const blocked = table.detect("api call pending [y/n]").?;
    try std.testing.expectEqual(Status.blocked, blocked.status);
    try std.testing.expectEqual(types.AgentProvider.unknown, blocked.provider);
    try std.testing.expect(table.detect("pi> ") == null);

    var extended = builtin_table;
    const same = try extended.add("pi");
    try std.testing.expectEqual(types.AgentProvider.pi, same.provider);
    try same.working.append("thinking");
    try std.testing.expectEqual(types.first_custom_agent_provider, @intFromEnum((try extended.add("gemini")).provider));
}

test "custom agents receive stable provider indexes and extend built-ins by name" {
    var table = builtin_table;

    const gemini = try table.add("gemini");
    try gemini.process_names.append("gemini");
    try gemini.identity.append("gemini cli");
    try std.testing.expectEqual(types.first_custom_agent_provider, @intFromEnum(gemini.provider));

    const aider = try table.add("aider");
    try std.testing.expectEqual(types.first_custom_agent_provider + 1, @intFromEnum(aider.provider));
    try std.testing.expectError(error.DuplicateName, table.add("gemini"));
    try std.testing.expectError(error.InvalidName, table.add("Gemini"));

    const extended = try table.add("claude");
    try std.testing.expectEqual(types.AgentProvider.claude, extended.provider);
    try extended.working.append("brewing");

    try std.testing.expectEqual(gemini.provider, table.detect("Gemini CLI ready").?.provider);
    try std.testing.expectEqual(Status.working, table.detect("Brewing...").?.status);
    try std.testing.expectEqualStrings("gemini", table.providerName(gemini.provider));
    try std.testing.expectEqual(gemini.provider, table.providerFromExecutable("gemini").?);
}

test "phrase lists reject empty, oversized and excess entries" {
    var list: PhraseList = .{};
    try std.testing.expectError(error.EmptyEntry, list.append(""));
    try std.testing.expectError(error.EntryTooLong, list.append("x" ** (max_phrase_bytes + 1)));
    for (0..max_phrases) |_| try list.append("ok");
    try std.testing.expectError(error.TooManyEntries, list.append("ok"));
}

test "presentation defaults derive from the manifest and configuration overrides them" {
    var table = builtin_table;
    var buffer: [types.max_agent_session_title_bytes]u8 = undefined;

    try std.testing.expectEqualStrings("Claude Code", table.displayName(.claude));
    try std.testing.expectEqualStrings("New Claude Code session", table.placeholderTitle(.claude, &buffer));
    try std.testing.expectEqualStrings("", table.icon(.claude));
    try std.testing.expectEqual(types.AgentAttachmentMarkers.stable_number, table.attachments(.claude));
    try std.testing.expectEqual(types.AgentAttachmentMarkers.ordered, table.attachments(.codex));
    try std.testing.expectEqual(types.AgentAttachmentMarkers.pasted_path, table.attachments(.pi));

    try std.testing.expectEqualStrings(generic_display_name, table.displayName(.unknown));
    try std.testing.expectEqualStrings(generic_placeholder, table.placeholderTitle(.unknown, &buffer));
    try std.testing.expectEqual(types.AgentAttachmentMarkers.none, table.attachments(.unknown));
    try std.testing.expect(table.declaresReadyPrompt(.codex));
    try std.testing.expect(!table.declaresReadyPrompt(.claude));
    try std.testing.expect(!table.declaresReadyPrompt(.unknown));

    const gemini = try table.add("gemini");
    try std.testing.expectEqualStrings("gemini", table.displayName(gemini.provider));
    try std.testing.expectEqualStrings("New gemini session", table.placeholderTitle(gemini.provider, &buffer));
    try gemini.setDisplayName("Gemini CLI");
    try gemini.setPlaceholder("Fresh Gemini chat");
    try gemini.setIcon("G");
    gemini.attachments = .ordered;
    try std.testing.expectEqualStrings("Gemini CLI", table.displayName(gemini.provider));
    try std.testing.expectEqualStrings("Fresh Gemini chat", table.placeholderTitle(gemini.provider, &buffer));
    try std.testing.expectEqualStrings("G", table.icon(gemini.provider));
    try std.testing.expectEqual(types.AgentAttachmentMarkers.ordered, table.attachments(gemini.provider));

    const claude = try table.add("claude");
    try claude.setDisplayName("Claude");
    try std.testing.expectEqualStrings("New Claude session", table.placeholderTitle(.claude, &buffer));

    try std.testing.expectError(error.EmptyText, gemini.setIcon(""));
    try std.testing.expectError(error.TextTooLong, gemini.setIcon("x" ** (types.max_agent_icon_bytes + 1)));
    try std.testing.expectError(error.TextTooLong, gemini.setDisplayName("x" ** (types.max_agent_display_name_bytes + 1)));
}
