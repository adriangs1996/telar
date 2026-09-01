//! Data-driven agent identification shared by the runtime and the config
//! loader. A manifest names one agent CLI and the bounded phrases that
//! identify its process and its visible states, so adding an agent needs
//! configuration rather than a rebuild.

const std = @import("std");
const schema = @import("schema/root.zig");

pub const AgentProvider = schema.AgentProvider;

pub const max_agents = schema.max_agent_manifests;
pub const max_name_bytes = schema.max_agent_provider_name_bytes;
pub const max_phrase_bytes = 48;
pub const max_phrases = 8;
pub const max_path_bytes = 64;
pub const max_paths = 4;
pub const first_custom_provider: u8 = schema.first_custom_agent_provider;

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

pub const Manifest = struct {
    provider: AgentProvider,
    name: [max_name_bytes]u8 = undefined,
    name_len: u8 = 0,
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
};

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
            if (existing.provider == .claude or existing.provider == .codex) return existing;
            return error.DuplicateName;
        }
        if (table.count == max_agents) return error.TooManyAgents;

        const provider: AgentProvider = if (std.mem.eql(u8, name, "claude"))
            .claude
        else if (std.mem.eql(u8, name, "codex"))
            .codex
        else
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
    for ([_][]const u8{ "claude", "claude-code" }) |name| claude.process_names.append(name) catch unreachable;
    for ([_][]const u8{ "/@anthropic-ai/claude-code/", "\\@anthropic-ai\\claude-code\\" }) |path| claude.process_paths.append(path) catch unreachable;
    claude.brand.append("claude") catch unreachable;
    claude.identity.append("claude code") catch unreachable;
    for (shared_blocked) |phrase| claude.blocked.append(phrase) catch unreachable;
    for (shared_working) |phrase| claude.working.append(phrase) catch unreachable;

    const codex = table.add("codex") catch unreachable;
    codex.process_names.append("codex") catch unreachable;
    for ([_][]const u8{ "/@openai/codex/", "\\@openai\\codex\\" }) |path| codex.process_paths.append(path) catch unreachable;
    codex.brand.append("codex") catch unreachable;
    codex.ready_prompt.append("ask codex to do anything") catch unreachable;

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
