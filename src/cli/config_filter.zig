//! What happens to a configuration file before it leaves this machine
//! (docs/plans/machine-setup.md, decision 2): keys that carry secrets or
//! MCP servers are dropped, at any depth, and this home's paths become the
//! machine's. JSONC is read by removing its comments and trailing commas,
//! so the machine gets plain JSON. Codex's TOML is filtered line by line,
//! since no TOML parser exists here: a table whose path holds a dropped name
//! goes whole, a key whose dotted path holds one goes with every line of its
//! value, and multi-line strings and arrays are followed so their lines are
//! never read as keys. Each dropped key is named so setup can report it.
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

/// Fragments that mark a key as a secret whatever its value.
const secret_fragments = [_][]const u8{
    "secret",
    "password",
    "passphrase",
    "apikey",
    "api_key",
    "api-key",
    "credential",
    "bearer",
    "private_key",
    "privatekey",
    "authorization",
    "cookie",
};

/// Fragments that mark a key as a secret unless its value is a number or a
/// boolean: `githubToken` and `x-auth` go, `max_tokens = 4096` and
/// `requires_openai_auth = true` stay.
const secret_text_fragments = [_][]const u8{ "token", "auth" };

/// TOML tables dropped whole: MCP servers, per-project trust (this
/// machine's paths) and the environment Codex passes to commands.
const dropped_tables = [_][]const u8{ "mcp_servers", "projects", "shell_environment_policy" };

/// What a key holds, as far as deciding whether it is a secret goes.
const ValueKind = enum {
    /// A number or a boolean: no credential fits in one.
    scalar,
    /// A string.
    text,
    /// A table, an object or an array.
    container,
};

/// Whether a key carries a secret or an MCP server and is never sent.
///
/// ```zig
/// if (config_filter.secretKey("apiKey", .text)) ...
/// ```
pub fn secretKey(name: []const u8, value: ValueKind) bool {
    for (dropped_names) |dropped| {
        if (std.mem.eql(u8, name, dropped)) {
            return true;
        }
    }

    for (secret_fragments) |fragment| {
        if (std.ascii.indexOfIgnoreCase(name, fragment) != null) {
            return true;
        }
    }

    if (value == .scalar) {
        return false;
    }

    for (secret_text_fragments) |fragment| {
        if (std.ascii.indexOfIgnoreCase(name, fragment) != null) {
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
                if (secretKey(key, jsonKind(object.values()[index]))) {
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

fn jsonKind(value: std.json.Value) ValueKind {
    return switch (value) {
        .bool, .integer, .float, .number_string, .null => .scalar,
        .string => .text,
        .object, .array => .container,
    };
}

fn noteOnce(arena: std.mem.Allocator, dropped: *std.ArrayList([]const u8), name: []const u8) !void {
    for (dropped.items) |known| {
        if (std.mem.eql(u8, known, name)) {
            return;
        }
    }

    try dropped.append(arena, name);
}

/// Codex's `config.toml` without its secret tables and keys: a table whose
/// path holds a dropped or secret name (`[mcp_servers.x]`,
/// `[model_providers.x.http_headers]`) goes whole, and so does a key whose
/// dotted path holds one (`http_headers.Authorization = …`), with every
/// line its value spans. The result belongs to `gpa`.
///
/// ```zig
/// const toml = try config_filter.filterToml(gpa, bytes, arena, &dropped);
/// ```
pub fn filterToml(gpa: std.mem.Allocator, bytes: []const u8, arena: std.mem.Allocator, dropped: *std.ArrayList([]const u8)) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(gpa);
    errdefer output.deinit();

    var skipping_table = false;
    var value: TomlValue = .{};
    var dropping_value = false;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var first = true;
    while (lines.next()) |line| {
        var keep = !skipping_table;
        if (value.open()) {
            value.scan(line);
            keep = keep and !dropping_value;
        } else {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len != 0 and trimmed[0] == '[') {
                const offending = tomlPathSecret(tomlHeader(trimmed), .container);
                skipping_table = offending != null;
                keep = !skipping_table;
                if (offending) |name| {
                    try noteOnce(arena, dropped, try arena.dupe(u8, name));
                }
            } else if (tomlEquals(trimmed)) |equals| {
                const rest = std.mem.trim(u8, trimmed[equals + 1 ..], " \t");
                const offending = tomlPathSecret(trimmed[0..equals], tomlKind(rest));
                dropping_value = offending != null;
                value.scan(rest);
                if (offending) |name| {
                    keep = false;
                    if (!skipping_table) {
                        try noteOnce(arena, dropped, try arena.dupe(u8, name));
                    }
                }
            }
        }

        if (!keep) {
            continue;
        }

        if (!first) {
            try output.writer.writeByte('\n');
        }

        first = false;
        try output.writer.writeAll(line);
    }

    return output.toOwnedSlice();
}

/// Where a TOML value stands at the end of a line: inside a multi-line
/// string, or inside brackets or braces not yet closed.
const TomlValue = struct {
    string: ?Delimiter = null,
    depth: i32 = 0,

    const Delimiter = enum { basic, literal };

    fn open(self: *const TomlValue) bool {
        return self.string != null or self.depth > 0;
    }

    // Follows one line of a value: strings, brackets and a trailing comment.
    fn scan(self: *TomlValue, text: []const u8) void {
        var index: usize = 0;
        while (index < text.len) {
            if (self.string) |delimiter| {
                switch (delimiter) {
                    .basic => {
                        if (text[index] == '\\') {
                            index += 2;
                            continue;
                        }

                        if (std.mem.startsWith(u8, text[index..], "\"\"\"")) {
                            self.string = null;
                            index += 3;
                            continue;
                        }
                    },
                    .literal => if (std.mem.startsWith(u8, text[index..], "'''")) {
                        self.string = null;
                        index += 3;
                        continue;
                    },
                }

                index += 1;
                continue;
            }

            if (std.mem.startsWith(u8, text[index..], "\"\"\"")) {
                self.string = .basic;
                index += 3;
                continue;
            }

            if (std.mem.startsWith(u8, text[index..], "'''")) {
                self.string = .literal;
                index += 3;
                continue;
            }

            switch (text[index]) {
                '#' => return,
                '"', '\'' => index = skipQuoted(text, index),
                '[', '{' => self.depth += 1,
                ']', '}' => self.depth -= 1,
                else => {},
            }

            index += 1;
        }
    }
};

// The index of the quote closing the one-line string that opens at `start`.
fn skipQuoted(text: []const u8, start: usize) usize {
    const quote = text[start];
    var index = start + 1;
    while (index < text.len and text[index] != quote) {
        index += if (quote == '"' and text[index] == '\\') 2 else 1;
    }

    return @min(index, text.len);
}

// The path inside a `[table]` or `[[array]]` header, without its comment.
fn tomlHeader(trimmed: []const u8) []const u8 {
    var inner = std.mem.trimStart(u8, trimmed, "[");
    var index: usize = 0;
    while (index < inner.len and inner[index] != ']') {
        index = if (inner[index] == '"' or inner[index] == '\'') skipQuoted(inner, index) + 1 else index + 1;
    }

    inner = inner[0..@min(index, inner.len)];
    return inner;
}

// Where a key's `=` is, outside quoted parts of the key.
fn tomlEquals(trimmed: []const u8) ?usize {
    if (trimmed.len == 0 or trimmed[0] == '#') {
        return null;
    }

    var index: usize = 0;
    while (index < trimmed.len) {
        switch (trimmed[index]) {
            '=' => return index,
            '"', '\'' => index = skipQuoted(trimmed, index) + 1,
            else => index += 1,
        }
    }

    return null;
}

fn tomlKind(value: []const u8) ValueKind {
    if (value.len == 0) {
        return .text;
    }

    return switch (value[0]) {
        '"', '\'' => .text,
        '[', '{' => .container,
        else => .scalar,
    };
}

// The first component of a dotted TOML path that is a dropped table or a
// secret key; the last component holds a value of `last`, the others
// tables.
fn tomlPathSecret(path: []const u8, last: ValueKind) ?[]const u8 {
    var components: [max_toml_components][]const u8 = undefined;
    var count: usize = 0;
    var index: usize = 0;
    var start: usize = 0;
    while (index <= path.len) {
        if (index == path.len or path[index] == '.') {
            if (count == components.len) {
                // Deeper than any real configuration: refuse it whole.
                return path;
            }

            components[count] = std.mem.trim(u8, std.mem.trim(u8, path[start..index], " \t"), "\"'");
            count += 1;
            start = index + 1;
            index += 1;
            continue;
        }

        index = if (path[index] == '"' or path[index] == '\'') skipQuoted(path, index) + 1 else index + 1;
    }

    for (dropped_tables) |table| {
        if (std.mem.eql(u8, components[0], table)) {
            return components[0];
        }
    }

    for (components[0..count], 0..) |component, position| {
        if (secretKey(component, if (position + 1 == count) last else .container)) {
            return component;
        }
    }

    return null;
}

/// Components of a dotted TOML path read, at most.
const max_toml_components = 16;
