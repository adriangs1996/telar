//! What happens to a configuration file before it leaves this machine
//! (docs/plans/machine-setup.md, decision 2): keys that carry secrets or
//! MCP servers are dropped, at any depth, and this home's paths become the
//! machine's. JSONC is read by removing its comments and trailing commas,
//! so the machine gets plain JSON. Codex's TOML is filtered by whole tables
//! and keys, since no TOML parser exists here. Each dropped key is named so
//! setup can report it.
const std = @import("std");

/// Key names dropped wherever they appear: environment blocks, headers,
/// credential helpers, account data and MCP servers.
const dropped_names = [_][]const u8{
    "env",
    "environment",
    "headers",
    "http_headers",
    "env_http_headers",
    "auth",
    "authInfo",
    "apiKeyHelper",
    "awsAuthRefresh",
    "awsCredentialExport",
    "otelHeadersHelper",
    "mcpServers",
    "mcp",
    "mcp_servers",
    "token",
    "accessToken",
    "access_token",
    "refreshToken",
    "refresh_token",
    "idToken",
    "id_token",
};

/// Fragments that mark a key as a secret whatever else it says.
const secret_fragments = [_][]const u8{ "secret", "password", "apikey", "api_key", "credential", "bearer", "private_key", "privatekey" };

/// TOML tables dropped whole: MCP servers, per-project trust (this
/// machine's paths) and the environment Codex passes to commands.
const dropped_tables = [_][]const u8{ "mcp_servers", "projects", "shell_environment_policy" };

/// Whether a key carries a secret or an MCP server and is never sent.
///
/// ```zig
/// if (config_filter.secretKey("apiKey")) ...
/// ```
pub fn secretKey(name: []const u8) bool {
    for (dropped_names) |dropped| {
        if (std.mem.eql(u8, name, dropped)) {
            return true;
        }
    }

    var lower_buffer: [128]u8 = undefined;
    if (name.len > lower_buffer.len) {
        return false;
    }

    const lower = std.ascii.lowerString(&lower_buffer, name);
    for (secret_fragments) |fragment| {
        if (std.mem.indexOf(u8, lower, fragment) != null) {
            return true;
        }
    }

    return false;
}

/// Replaces `from/` with `to/` everywhere in `bytes`, and a string that is
/// exactly `from` with `to`. The result belongs to `gpa`.
///
/// ```zig
/// const text = try config_filter.rewriteHome(gpa, bytes, "/Users/ana", "/home/ana");
/// ```
pub fn rewriteHome(gpa: std.mem.Allocator, bytes: []const u8, from: []const u8, to: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(gpa);
    errdefer output.deinit();

    var rest = bytes;
    while (std.mem.indexOf(u8, rest, from)) |at| {
        const after = at + from.len;
        const ends_path = after == rest.len or rest[after] == '/' or rest[after] == '"' or rest[after] == '\'' or std.ascii.isWhitespace(rest[after]);
        try output.writer.writeAll(rest[0..at]);
        try output.writer.writeAll(if (ends_path) to else from);
        rest = rest[after..];
    }

    try output.writer.writeAll(rest);
    return output.toOwnedSlice();
}

/// Removes `//` and `/* */` comments outside strings and commas that close
/// an object or array, so `std.json` reads JSONC. The result belongs to
/// `gpa`.
///
/// ```zig
/// const plain = try config_filter.stripJsonc(gpa, "{\"a\": 1, // one\n}");
/// ```
pub fn stripJsonc(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);
    try output.ensureTotalCapacity(gpa, bytes.len);

    var index: usize = 0;
    var in_string = false;
    while (index < bytes.len) : (index += 1) {
        const byte = bytes[index];
        if (in_string) {
            output.appendAssumeCapacity(byte);
            if (byte == '\\' and index + 1 < bytes.len) {
                index += 1;
                output.appendAssumeCapacity(bytes[index]);
            } else if (byte == '"') {
                in_string = false;
            }

            continue;
        }

        if (byte == '"') {
            in_string = true;
            output.appendAssumeCapacity(byte);
        } else if (byte == '/' and index + 1 < bytes.len and bytes[index + 1] == '/') {
            index = std.mem.indexOfScalarPos(u8, bytes, index, '\n') orelse bytes.len;
            if (index < bytes.len) {
                output.appendAssumeCapacity('\n');
            }
        } else if (byte == '/' and index + 1 < bytes.len and bytes[index + 1] == '*') {
            const end = std.mem.indexOfPos(u8, bytes, index + 2, "*/") orelse return error.UnterminatedComment;
            index = end + 1;
        } else if (byte == ',' and closesNext(bytes, index + 1)) {
            continue;
        } else {
            output.appendAssumeCapacity(byte);
        }
    }

    return output.toOwnedSlice(gpa);
}

// Whether only whitespace or comments stand between `start` and a `}` or `]`.
fn closesNext(bytes: []const u8, start: usize) bool {
    var index = start;
    while (index < bytes.len) {
        const byte = bytes[index];
        if (std.ascii.isWhitespace(byte)) {
            index += 1;
        } else if (byte == '/' and index + 1 < bytes.len and bytes[index + 1] == '/') {
            index = std.mem.indexOfScalarPos(u8, bytes, index, '\n') orelse return false;
        } else if (byte == '/' and index + 1 < bytes.len and bytes[index + 1] == '*') {
            index = (std.mem.indexOfPos(u8, bytes, index + 2, "*/") orelse return false) + 2;
        } else {
            return byte == '}' or byte == ']';
        }
    }

    return false;
}

/// Drops every secret key of `value`, at any depth, and appends each
/// dropped name to `dropped`, once.
///
/// ```zig
/// try config_filter.dropSecrets(arena, &parsed.value, &dropped);
/// ```
pub fn dropSecrets(arena: std.mem.Allocator, value: *std.json.Value, dropped: *std.ArrayList([]const u8)) !void {
    switch (value.*) {
        .object => |*object| {
            var index: usize = 0;
            while (index < object.count()) {
                const key = object.keys()[index];
                if (secretKey(key)) {
                    try noteOnce(arena, dropped, key);
                    object.orderedRemoveAt(index);
                    continue;
                }

                try dropSecrets(arena, &object.values()[index], dropped);
                index += 1;
            }
        },
        .array => |*array| {
            for (array.items) |*item| {
                try dropSecrets(arena, item, dropped);
            }
        },
        else => {},
    }
}

fn noteOnce(arena: std.mem.Allocator, dropped: *std.ArrayList([]const u8), name: []const u8) !void {
    for (dropped.items) |known| {
        if (std.mem.eql(u8, known, name)) {
            return;
        }
    }

    try dropped.append(arena, name);
}

/// Codex's `config.toml` without its secret tables and keys. A dropped key
/// whose value spans lines takes those lines with it. The result belongs
/// to `gpa`.
///
/// ```zig
/// const toml = try config_filter.filterToml(gpa, bytes, arena, &dropped);
/// ```
pub fn filterToml(gpa: std.mem.Allocator, bytes: []const u8, arena: std.mem.Allocator, dropped: *std.ArrayList([]const u8)) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(gpa);
    errdefer output.deinit();

    var skipping_table = false;
    var open_brackets: i32 = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var first = true;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (open_brackets > 0) {
            open_brackets += bracketBalance(trimmed);
            continue;
        }

        if (trimmed.len != 0 and trimmed[0] == '[') {
            const name = std.mem.trim(u8, std.mem.trim(u8, trimmed, "[] \t"), "\"");
            skipping_table = droppedTable(name);
            if (skipping_table) {
                try noteOnce(arena, dropped, tableRoot(name));
                continue;
            }
        } else if (skipping_table) {
            continue;
        } else if (std.mem.indexOfScalar(u8, trimmed, '=')) |equals| {
            const key = std.mem.trim(u8, trimmed[0..equals], " \t\"");
            const dotted = if (std.mem.lastIndexOfScalar(u8, key, '.')) |dot| key[dot + 1 ..] else key;
            if (secretKey(dotted) or droppedTable(key)) {
                try noteOnce(arena, dropped, try arena.dupe(u8, dotted));
                open_brackets = bracketBalance(trimmed[equals + 1 ..]);
                continue;
            }
        }

        if (!first) {
            try output.writer.writeByte('\n');
        }

        first = false;
        try output.writer.writeAll(line);
    }

    return output.toOwnedSlice();
}

fn droppedTable(name: []const u8) bool {
    const root = tableRoot(name);
    for (dropped_tables) |table| {
        if (std.mem.eql(u8, root, table)) {
            return true;
        }
    }

    return false;
}

fn tableRoot(name: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, name, '.') orelse name.len;
    return std.mem.trim(u8, name[0..end], "\" ");
}

// Opening minus closing brackets and braces outside strings.
fn bracketBalance(text: []const u8) i32 {
    var balance: i32 = 0;
    var quote: ?u8 = null;
    for (text) |byte| {
        if (quote) |open| {
            if (byte == open) {
                quote = null;
            }

            continue;
        }

        switch (byte) {
            '"', '\'' => quote = byte,
            '[', '{' => balance += 1,
            ']', '}' => balance -= 1,
            '#' => break,
            else => {},
        }
    }

    return balance;
}

test "secret keys are dropped at any depth and named once" {
    const source =
        \\{"model":"opus","env":{"ANTHROPIC_API_KEY":"sk-1"},"apiKeyHelper":"/bin/key",
        \\ "provider":{"x":{"options":{"apiKey":"sk-2","baseURL":"https://x"}}},
        \\ "mcpServers":{"a":{}},"permissions":{"allow":["Bash(ls)"]},"maxTokens":8}
    ;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var value = try std.json.parseFromSliceLeaky(std.json.Value, arena, source, .{});
    var dropped: std.ArrayList([]const u8) = .empty;
    try dropSecrets(arena, &value, &dropped);

    const written = try std.json.Stringify.valueAlloc(arena, value, .{});
    try std.testing.expectEqualStrings(
        "{\"model\":\"opus\",\"provider\":{\"x\":{\"options\":{\"baseURL\":\"https://x\"}}},\"permissions\":{\"allow\":[\"Bash(ls)\"]},\"maxTokens\":8}",
        written,
    );
    try std.testing.expectEqual(@as(usize, 4), dropped.items.len);
}

test "JSONC loses its comments and trailing commas, not its strings" {
    const plain = try stripJsonc(std.testing.allocator,
        \\{
        \\  // a comment
        \\  "url": "https://x//y", /* block */
        \\  "list": [1, 2,],
        \\}
    );
    defer std.testing.allocator.free(plain);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, plain, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("https://x//y", parsed.value.object.get("url").?.string);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.object.get("list").?.array.items.len);
}

test "this home becomes the machine's only as a whole path" {
    const text = try rewriteHome(std.testing.allocator, "cmd /Users/ana/x \"/Users/ana\" /Users/anabel/y", "/Users/ana", "/home/ana");
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("cmd /home/ana/x \"/home/ana\" /Users/anabel/y", text);
}

test "codex's config loses MCP servers, projects and secret keys" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dropped: std.ArrayList([]const u8) = .empty;

    const toml = try filterToml(std.testing.allocator,
        \\model = "gpt-5"
        \\experimental_bearer_token = "abc"
        \\notify = ["/Users/ana/notify.sh"]
        \\
        \\[mcp_servers.docs]
        \\command = "npx"
        \\env = { TOKEN = "x" }
        \\
        \\[projects."/Users/ana/src"]
        \\trust_level = "trusted"
        \\
        \\[model_providers.x]
        \\base_url = "https://x"
        \\http_headers = {
        \\  "Authorization" = "Bearer y",
        \\}
        \\wire_api = "responses"
    , arena, &dropped);
    defer std.testing.allocator.free(toml);

    try std.testing.expectEqualStrings(
        "model = \"gpt-5\"\nnotify = [\"/Users/ana/notify.sh\"]\n\n[model_providers.x]\nbase_url = \"https://x\"\nwire_api = \"responses\"",
        toml,
    );
    try std.testing.expectEqual(@as(usize, 4), dropped.items.len);
}
