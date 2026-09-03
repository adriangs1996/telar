//! Data-driven agent identification shared by the runtime and the config
//! loader. A manifest names one agent CLI and the bounded phrases that
//! identify its process and its visible states, so adding an agent needs
//! configuration rather than a rebuild.

const std = @import("std");
const schema = @import("schema/root.zig");

pub const AgentProvider = schema.AgentProvider;

pub const max_agents = schema.max_agent_manifests;
pub const max_name_bytes = schema.max_agent_provider_name_bytes;
pub const max_display_name_bytes = schema.max_agent_display_name_bytes;
pub const max_placeholder_bytes = schema.max_agent_session_title_bytes;
pub const max_icon_bytes = schema.max_agent_icon_bytes;
pub const max_phrase_bytes = 48;
pub const max_phrases = 8;
pub const max_path_bytes = 64;
pub const max_paths = 4;
pub const first_custom_provider: u8 = schema.first_custom_agent_provider;

/// Labels for an agent the table does not know. Clients and the runtime use
/// the same words so an unknown agent reads identically everywhere.
pub const generic_display_name = "Agent";
pub const generic_placeholder = "New agent session";

pub const AttachmentMarkers = schema.AgentAttachmentMarkers;

pub const Status = enum { working, blocked, ready };

/// One screen heuristic result. Heuristics change presentation only; they
/// never authorize input.
pub const Signal = struct {
    provider: AgentProvider = .unknown,
    status: Status,
    confidence: u8,
    identity_confirmed: bool = false,
    /// The sample contains an input prompt which proves the agent is waiting.
    /// Provider branding alone confirms identity, not readiness.
    ready_confirmed: bool = false,
};

pub const ListError = error{ TooManyEntries, EntryTooLong, EmptyEntry };

/// Fixed-capacity list of short byte strings.
pub fn BoundedList(comptime capacity: usize, comptime entry_bytes: usize) type {
    return struct {
        const Self = @This();

        pub const max_entries = capacity;

        items: [capacity][entry_bytes]u8 = undefined,
        lens: [capacity]u8 = undefined,
        count: u8 = 0,

        pub fn append(list: *Self, text: []const u8) ListError!void {
            if (text.len == 0) return error.EmptyEntry;
            if (text.len > entry_bytes) return error.EntryTooLong;
            if (list.count == capacity) return error.TooManyEntries;
            @memcpy(list.items[list.count][0..text.len], text);
            list.lens[list.count] = @intCast(text.len);
            list.count += 1;
        }

        pub fn get(list: *const Self, index: usize) []const u8 {
            return list.items[index][0..list.lens[index]];
        }

        /// Reports whether any entry occurs in `haystack`, ASCII
        /// case-insensitively.
        pub fn matches(list: *const Self, haystack: []const u8) bool {
            for (0..list.count) |index| {
                if (containsAsciiInsensitive(haystack, list.get(index))) return true;
            }
            return false;
        }
    };
}

pub const PhraseList = BoundedList(max_phrases, max_phrase_bytes);
pub const PathList = BoundedList(max_paths, max_path_bytes);

pub const TextError = error{ EmptyText, TextTooLong };

pub const Manifest = struct {
    provider: AgentProvider,
    name: [max_name_bytes]u8 = undefined,
    name_len: u8 = 0,
    /// Human label shown wherever the agent is named; defaults to `name`.
    display_name: [max_display_name_bytes]u8 = undefined,
    display_name_len: u8 = 0,
    /// Session title shown until the agent has a real one; defaults to
    /// "New <display name> session".
    placeholder: [max_placeholder_bytes]u8 = undefined,
    placeholder_len: u8 = 0,
    /// One sidebar glyph. Empty leaves the choice to the client, which has
    /// artwork for the built-in agents and a generic mark for the rest.
    icon: [max_icon_bytes]u8 = undefined,
    icon_len: u8 = 0,
    /// How the agent's prompt identifies pasted images; `none` disables the
    /// image shelf for this agent.
    attachments: AttachmentMarkers = .none,
    /// Executable basenames, compared without `.exe`, `.cmd`, `.bat` or `.js`.
    process_names: PathList = .{},
    /// Path fragments of an interpreter-launched entry point.
    process_paths: PathList = .{},
    /// Words that attribute a generic working or blocked phrase to this agent.
    brand: PhraseList = .{},
    /// Phrases that confirm the agent's identity on screen without proving
    /// readiness.
    identity: PhraseList = .{},
    working: PhraseList = .{},
    blocked: PhraseList = .{},
    /// Prompt text that proves the agent is idle and waiting for input.
    ready_prompt: PhraseList = .{},

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
    pub fn placeholderTitle(manifest: *const Manifest, buffer: *[max_placeholder_bytes]u8) []const u8 {
        if (manifest.placeholder_len != 0) {
            return manifest.placeholder[0..manifest.placeholder_len];
        }

        return std.fmt.bufPrint(buffer, "New {s} session", .{manifest.displayName()}) catch unreachable;
    }

    pub fn setDisplayName(manifest: *Manifest, text: []const u8) TextError!void {
        manifest.display_name_len = try copyText(&manifest.display_name, text);
    }

    pub fn setPlaceholder(manifest: *Manifest, text: []const u8) TextError!void {
        manifest.placeholder_len = try copyText(&manifest.placeholder, text);
    }

    pub fn setIcon(manifest: *Manifest, text: []const u8) TextError!void {
        manifest.icon_len = try copyText(&manifest.icon, text);
    }

    comptime {
        // "New " + display name + " session" must always fit the placeholder.
        std.debug.assert(4 + max_display_name_bytes + 8 <= max_placeholder_bytes);
    }
};

fn copyText(storage: []u8, text: []const u8) TextError!u8 {
    if (text.len == 0) return error.EmptyText;
    if (text.len > storage.len) return error.TextTooLong;
    @memcpy(storage[0..text.len], text);
    return @intCast(text.len);
}

pub const AddError = error{ TooManyAgents, InvalidName, DuplicateName };

pub const Table = struct {
    items: [max_agents]Manifest = undefined,
    count: u8 = 0,

    /// Registers one agent. Built-in names return their existing manifest so
    /// configuration can extend the phrases; new names receive the next
    /// custom provider index.
    ///
    /// ```zig
    /// const gemini = try table.add("gemini");
    /// try gemini.process_names.append("gemini");
    /// ```
    pub fn add(table: *Table, name: []const u8) AddError!*Manifest {
        if (!validName(name)) return error.InvalidName;
        if (table.findByName(name)) |existing| {
            if (isBuiltinProvider(existing.provider)) return existing;
            return error.DuplicateName;
        }
        if (table.count == max_agents) return error.TooManyAgents;

        const provider: AgentProvider = builtinProvider(name) orelse
            @enumFromInt(first_custom_provider + table.customCount());
        const manifest = &table.items[table.count];
        manifest.* = .{ .provider = provider };
        @memcpy(manifest.name[0..name.len], name);
        manifest.name_len = @intCast(name.len);
        table.count += 1;
        return manifest;
    }

    pub fn slice(table: *const Table) []const Manifest {
        return table.items[0..table.count];
    }

    pub fn find(table: *const Table, provider: AgentProvider) ?*const Manifest {
        for (table.slice()) |*manifest| {
            if (manifest.provider == provider) return manifest;
        }
        return null;
    }

    pub fn findByName(table: *Table, name: []const u8) ?*Manifest {
        for (table.items[0..table.count]) |*manifest| {
            if (std.mem.eql(u8, manifest.nameSlice(), name)) return manifest;
        }
        return null;
    }

    /// Display name for a provider index; unknown indexes read as "unknown".
    ///
    /// ```zig
    /// const name = table.providerName(entry.provider);
    /// ```
    pub fn providerName(table: *const Table, provider: AgentProvider) []const u8 {
        const manifest = table.find(provider) orelse return "unknown";
        return manifest.nameSlice();
    }

    /// Human label for a provider index; unknown indexes read as "Agent".
    ///
    /// ```zig
    /// const label = table.displayName(entry.provider);
    /// ```
    pub fn displayName(table: *const Table, provider: AgentProvider) []const u8 {
        const manifest = table.find(provider) orelse return generic_display_name;
        return manifest.displayName();
    }

    /// Session title shown before an agent has a real one.
    ///
    /// ```zig
    /// var buffer: [max_placeholder_bytes]u8 = undefined;
    /// const title = table.placeholderTitle(entry.provider, &buffer);
    /// ```
    pub fn placeholderTitle(table: *const Table, provider: AgentProvider, buffer: *[max_placeholder_bytes]u8) []const u8 {
        const manifest = table.find(provider) orelse return generic_placeholder;
        return manifest.placeholderTitle(buffer);
    }

    /// Configured sidebar glyph; empty when the client should pick artwork.
    ///
    /// ```zig
    /// const glyph = table.icon(entry.provider);
    /// ```
    pub fn icon(table: *const Table, provider: AgentProvider) []const u8 {
        const manifest = table.find(provider) orelse return "";
        return manifest.iconSlice();
    }

    /// How the agent's prompt identifies pasted images.
    ///
    /// ```zig
    /// if (table.attachments(entry.provider) == .none) hideImageShelf();
    /// ```
    pub fn attachments(table: *const Table, provider: AgentProvider) AttachmentMarkers {
        const manifest = table.find(provider) orelse return .none;
        return manifest.attachments;
    }

    /// Reports whether the agent's manifest proves readiness by itself, so a
    /// generic screen scan must not override its stream signal.
    ///
    /// ```zig
    /// if (!table.declaresReadyPrompt(signal.provider)) mergeScreenScan();
    /// ```
    pub fn declaresReadyPrompt(table: *const Table, provider: AgentProvider) bool {
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
    pub fn providerFromExecutable(table: *const Table, basename: []const u8) ?AgentProvider {
        for (table.slice()) |*manifest| {
            for (0..manifest.process_names.count) |index| {
                if (equalExecutableName(basename, manifest.process_names.get(index))) return manifest.provider;
            }
        }
        return null;
    }

    /// Identifies an agent from a path fragment of its entry point.
    ///
    /// ```zig
    /// const provider = table.providerFromPath(argument) orelse return;
    /// ```
    pub fn providerFromPath(table: *const Table, path: []const u8) ?AgentProvider {
        for (table.slice()) |*manifest| {
            if (manifest.process_paths.matches(path)) return manifest.provider;
        }
        return null;
    }

    fn inferProvider(table: *const Table, text: []const u8) AgentProvider {
        for (table.slice()) |*manifest| {
            if (manifest.brand.matches(text)) return manifest.provider;
        }
        return .unknown;
    }

    fn customCount(table: *const Table) u8 {
        var count: u8 = 0;
        for (table.slice()) |*manifest| {
            if (@intFromEnum(manifest.provider) >= first_custom_provider) count += 1;
        }
        return count;
    }
};

/// Reports whether a provider ships with Telar. Only built-in providers may
/// carry a session resume command and keep their index across configurations.
///
/// ```zig
/// if (isBuiltinProvider(manifest.provider)) allowResume();
/// ```
pub fn isBuiltinProvider(provider: AgentProvider) bool {
    return switch (provider) {
        .claude, .codex, .pi => true,
        else => false,
    };
}

fn builtinProvider(name: []const u8) ?AgentProvider {
    if (std.mem.eql(u8, name, "claude")) return .claude;
    if (std.mem.eql(u8, name, "codex")) return .codex;
    if (std.mem.eql(u8, name, "pi")) return .pi;
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
    for (shared_blocked) |phrase| claude.blocked.append(phrase) catch unreachable;
    for (shared_working) |phrase| claude.working.append(phrase) catch unreachable;

    const codex = table.add("codex") catch unreachable;
    codex.setDisplayName("Codex") catch unreachable;
    codex.attachments = .ordered;
    codex.process_names.append("codex") catch unreachable;
    for ([_][]const u8{ "/@openai/codex/", "\\@openai\\codex\\" }) |path| codex.process_paths.append(path) catch unreachable;
    codex.brand.append("codex") catch unreachable;
    codex.ready_prompt.append("ask codex to do anything") catch unreachable;

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
    for ([_][]const u8{
        "/@earendil-works/pi-coding-agent/",
        "\\@earendil-works\\pi-coding-agent\\",
        "/@mariozechner/pi-coding-agent/",
        "\\@mariozechner\\pi-coding-agent\\",
    }) |path| pi.process_paths.append(path) catch unreachable;

    return table;
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_bytes) return false;
    for (name) |byte| {
        const ok = std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.';
        if (!ok or std.ascii.isUpper(byte)) return false;
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
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn endsWithAsciiInsensitive(haystack: []const u8, suffix: []const u8) bool {
    if (suffix.len > haystack.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[haystack.len - suffix.len ..], suffix);
}

test "built-in table reproduces the historical Claude and Codex heuristics" {
    const table = &builtin_table;

    const blocked = table.detect("Allow command? [y/n] claude").?;
    try std.testing.expectEqual(Status.blocked, blocked.status);
    try std.testing.expectEqual(AgentProvider.claude, blocked.provider);

    const working = table.detect("thinking... esc to interrupt").?;
    try std.testing.expectEqual(Status.working, working.status);
    try std.testing.expectEqual(AgentProvider.unknown, working.provider);

    const codex = table.detect("Ask Codex to do anything").?;
    try std.testing.expectEqual(Status.ready, codex.status);
    try std.testing.expectEqual(AgentProvider.codex, codex.provider);
    try std.testing.expect(codex.ready_confirmed);

    const claude = table.detect("Welcome to Claude Code").?;
    try std.testing.expectEqual(AgentProvider.claude, claude.provider);
    try std.testing.expect(claude.identity_confirmed);
    try std.testing.expect(!claude.ready_confirmed);

    try std.testing.expect(table.detect("$ ls") == null);
    try std.testing.expectEqual(AgentProvider.claude, table.providerFromExecutable("claude.exe").?);
    try std.testing.expectEqual(AgentProvider.codex, table.providerFromPath("/usr/lib/node_modules/@openai/codex/bin/codex.js").?);
    try std.testing.expectEqualStrings("codex", table.providerName(.codex));
    try std.testing.expectEqualStrings("unknown", table.providerName(.unknown));
}

test "built-in Pi is identified by its process and entry point only" {
    const table = &builtin_table;

    try std.testing.expectEqual(AgentProvider.pi, table.providerFromExecutable("pi").?);
    try std.testing.expectEqual(AgentProvider.pi, table.providerFromPath("/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js").?);
    try std.testing.expectEqual(AgentProvider.pi, table.providerFromPath("/usr/lib/node_modules/@mariozechner/pi-coding-agent/dist/cli.js").?);
    try std.testing.expectEqualStrings("pi", table.providerName(.pi));
    try std.testing.expect(isBuiltinProvider(.pi));
    try std.testing.expect(!isBuiltinProvider(@enumFromInt(first_custom_provider)));

    // No brand word: a generic blocked phrase next to "api" stays unattributed.
    const blocked = table.detect("api call pending [y/n]").?;
    try std.testing.expectEqual(Status.blocked, blocked.status);
    try std.testing.expectEqual(AgentProvider.unknown, blocked.provider);
    try std.testing.expect(table.detect("pi> ") == null);

    var extended = builtin_table;
    const same = try extended.add("pi");
    try std.testing.expectEqual(AgentProvider.pi, same.provider);
    try same.working.append("thinking");
    try std.testing.expectEqual(first_custom_provider, @intFromEnum((try extended.add("gemini")).provider));
}

test "custom agents receive stable provider indexes and extend built-ins by name" {
    var table = builtin_table;

    const gemini = try table.add("gemini");
    try gemini.process_names.append("gemini");
    try gemini.identity.append("gemini cli");
    try std.testing.expectEqual(first_custom_provider, @intFromEnum(gemini.provider));

    const aider = try table.add("aider");
    try std.testing.expectEqual(first_custom_provider + 1, @intFromEnum(aider.provider));
    try std.testing.expectError(error.DuplicateName, table.add("gemini"));
    try std.testing.expectError(error.InvalidName, table.add("Gemini"));

    const extended = try table.add("claude");
    try std.testing.expectEqual(AgentProvider.claude, extended.provider);
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
    var buffer: [max_placeholder_bytes]u8 = undefined;

    try std.testing.expectEqualStrings("Claude Code", table.displayName(.claude));
    try std.testing.expectEqualStrings("New Claude Code session", table.placeholderTitle(.claude, &buffer));
    try std.testing.expectEqualStrings("", table.icon(.claude));
    try std.testing.expectEqual(AttachmentMarkers.stable_number, table.attachments(.claude));
    try std.testing.expectEqual(AttachmentMarkers.ordered, table.attachments(.codex));
    try std.testing.expectEqual(AttachmentMarkers.pasted_path, table.attachments(.pi));

    try std.testing.expectEqualStrings(generic_display_name, table.displayName(.unknown));
    try std.testing.expectEqualStrings(generic_placeholder, table.placeholderTitle(.unknown, &buffer));
    try std.testing.expectEqual(AttachmentMarkers.none, table.attachments(.unknown));
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
    try std.testing.expectEqual(AttachmentMarkers.ordered, table.attachments(gemini.provider));

    const claude = try table.add("claude");
    try claude.setDisplayName("Claude");
    try std.testing.expectEqualStrings("New Claude session", table.placeholderTitle(.claude, &buffer));

    try std.testing.expectError(error.EmptyText, gemini.setIcon(""));
    try std.testing.expectError(error.TextTooLong, gemini.setIcon("x" ** (max_icon_bytes + 1)));
    try std.testing.expectError(error.TextTooLong, gemini.setDisplayName("x" ** (max_display_name_bytes + 1)));
}
