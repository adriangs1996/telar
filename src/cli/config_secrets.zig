//! Secrets written inline in a file `telar machine setup` would otherwise
//! sync (docs/plans/machine-setup.md, "What is synced"): a hook that posts to
//! a webhook with its key in the URL, `TOKEN=… cmd`, an `Authorization`
//! header, a subagent's frontmatter with an MCP server's key. Dropping keys
//! by name cannot see these, so every file is scanned after it is filtered,
//! and a file with a finding stays here and is listed for the person to
//! review.
//!
//! The scan is a heuristic over shapes secrets are written in: assignments
//! and headers whose name says secret, bearer tokens, credentials in URLs,
//! webhook URLs that carry their key, the prefixes of well-known token
//! formats and private key blocks. A secret with none of these shapes, such
//! as a bare random string under an innocent name, is not recognized.
const std = @import("std");

/// The shape a finding was recognized by; the report names it, never the
/// secret itself.
const Kind = enum {
    assignment,
    bearer,
    url_credentials,
    webhook,
    token_prefix,
    private_key,

    pub fn describe(self: Kind) []const u8 {
        return switch (self) {
            .assignment => "a value assigned to a secret-looking name",
            .bearer => "a bearer token",
            .url_credentials => "a password inside a URL",
            .webhook => "a webhook URL, whose path is its key",
            .token_prefix => "a token of a well-known format",
            .private_key => "a private key",
        };
    }
};

const Finding = struct {
    /// One-based line of the first finding.
    line: u32,
    kind: Kind,
};

/// Fewest characters a value needs to count as a secret.
const min_value_bytes = 3;
/// Fewest characters after `Bearer ` that count as its token.
const min_bearer_bytes = 8;

/// Name fragments that mark an assigned value as a secret.
const secret_name_fragments = [_][]const u8{
    "token",
    "secret",
    "passw",
    "api_key",
    "apikey",
    "api-key",
    "access_key",
    "accesskey",
    "private_key",
    "authorization",
    "credential",
    "webhook",
};

/// Whole names that mark an assigned value as a secret.
const secret_names = [_][]const u8{ "key", "auth", "pat", "pwd" };

/// Hosts and paths of webhook URLs whose path is the credential.
const webhook_markers = [_][]const u8{
    "hooks.slack.com/services/",
    "hooks.slack.com/workflows/",
    "hooks.slack.com/triggers/",
    "discord.com/api/webhooks/",
    "discordapp.com/api/webhooks/",
    ".webhook.office.com/",
    "outlook.office.com/webhook",
    "hooks.zapier.com/hooks/",
    "api.telegram.org/bot",
    "chat.googleapis.com/v1/spaces/",
};

/// A token format recognized by its prefix and the characters after it.
const TokenPrefix = struct {
    prefix: []const u8,
    min_rest: u8,
};

const token_prefixes = [_]TokenPrefix{
    .{ .prefix = "ghp_", .min_rest = 20 },
    .{ .prefix = "gho_", .min_rest = 20 },
    .{ .prefix = "ghu_", .min_rest = 20 },
    .{ .prefix = "ghs_", .min_rest = 20 },
    .{ .prefix = "ghr_", .min_rest = 20 },
    .{ .prefix = "github_pat_", .min_rest = 20 },
    .{ .prefix = "glpat-", .min_rest = 20 },
    .{ .prefix = "sk-", .min_rest = 20 },
    .{ .prefix = "xoxb-", .min_rest = 10 },
    .{ .prefix = "xoxp-", .min_rest = 10 },
    .{ .prefix = "xoxa-", .min_rest = 10 },
    .{ .prefix = "xoxr-", .min_rest = 10 },
    .{ .prefix = "xoxs-", .min_rest = 10 },
    .{ .prefix = "AKIA", .min_rest = 16 },
    .{ .prefix = "ASIA", .min_rest = 16 },
    .{ .prefix = "AIza", .min_rest = 30 },
    .{ .prefix = "npm_", .min_rest = 30 },
    .{ .prefix = "pypi-", .min_rest = 30 },
};

/// The first line of `bytes` that looks like it holds a secret.
///
/// ```zig
/// if (config_secrets.find(bytes)) |finding| try report.note(.configuration, "line {d}: {s}", .{ finding.line, finding.kind.describe() });
/// ```
pub fn find(bytes: []const u8) ?Finding {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var number: u32 = 1;
    while (lines.next()) |line| : (number +|= 1) {
        if (findInLine(line)) |kind| {
            return .{
                .line = number,
                .kind = kind,
            };
        }
    }

    return null;
}

fn findInLine(line: []const u8) ?Kind {
    if (std.mem.indexOf(u8, line, "PRIVATE KEY-----") != null) {
        return .private_key;
    }

    for (webhook_markers) |marker| {
        if (std.ascii.indexOfIgnoreCase(line, marker) != null) {
            return .webhook;
        }
    }

    if (tokenPrefix(line)) {
        return .token_prefix;
    }

    if (bearer(line)) {
        return .bearer;
    }

    if (urlCredentials(line)) {
        return .url_credentials;
    }

    if (assignment(line)) {
        return .assignment;
    }

    return null;
}

fn tokenByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}

fn tokenPrefix(line: []const u8) bool {
    for (token_prefixes) |known| {
        var start: usize = 0;
        while (std.mem.indexOfPos(u8, line, start, known.prefix)) |at| {
            start = at + 1;
            if (at != 0 and tokenByte(line[at - 1])) {
                continue;
            }

            var end = at + known.prefix.len;
            while (end < line.len and tokenByte(line[end])) {
                end += 1;
            }

            if (end - at - known.prefix.len >= known.min_rest) {
                return true;
            }
        }
    }

    return false;
}

// `Bearer ` followed by a literal token, not a variable or a template.
fn bearer(line: []const u8) bool {
    var start: usize = 0;
    while (std.ascii.indexOfIgnoreCasePos(line, start, "bearer")) |at| {
        start = at + 1;
        var index = at + "bearer".len;
        const spaces = index;
        while (index < line.len and (line[index] == ' ' or line[index] == '\t')) {
            index += 1;
        }

        if (index == spaces or index == line.len or placeholder(line[index])) {
            continue;
        }

        const value_start = index;
        while (index < line.len and (tokenByte(line[index]) or std.mem.indexOfScalar(u8, "._~+/=", line[index]) != null)) {
            index += 1;
        }

        if (index - value_start >= min_bearer_bytes) {
            return true;
        }
    }

    return false;
}

// `scheme://user:password@host`: a password written into a URL.
fn urlCredentials(line: []const u8) bool {
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, line, start, "://")) |at| {
        start = at + 3;
        var end = start;
        while (end < line.len and std.mem.indexOfScalar(u8, "/?# \t\"'`<>", line[end]) == null) {
            end += 1;
        }

        const authority = line[start..end];
        const at_sign = std.mem.lastIndexOfScalar(u8, authority, '@') orelse continue;
        const colon = std.mem.indexOfScalar(u8, authority[0..at_sign], ':') orelse continue;
        const password = authority[colon + 1 .. at_sign];
        if (password.len != 0 and !placeholder(password[0])) {
            return true;
        }
    }

    return false;
}

// `NAME=value`, `NAME: value`, `"NAME": "value"` or `--NAME value`-free
// header forms whose name says secret and whose value is written out.
fn assignment(line: []const u8) bool {
    var index: usize = 0;
    while (index < line.len) {
        if (!nameByte(line[index])) {
            index += 1;
            continue;
        }

        const name_start = index;
        while (index < line.len and nameByte(line[index])) {
            index += 1;
        }

        const name = line[name_start..index];
        var cursor = index;
        if (cursor < line.len and (line[cursor] == '"' or line[cursor] == '\'')) {
            cursor += 1;
        }

        while (cursor < line.len and (line[cursor] == ' ' or line[cursor] == '\t')) {
            cursor += 1;
        }

        if (cursor == line.len or (line[cursor] != '=' and line[cursor] != ':')) {
            continue;
        }

        // `https://` is a URL, `a == b` a comparison.
        if (line[cursor] == ':' and std.mem.startsWith(u8, line[cursor..], "://")) {
            continue;
        }

        cursor += 1;
        if (cursor < line.len and line[cursor] == '=') {
            continue;
        }

        if (secretName(name) and literalValue(line[cursor..], countsNumbers(name))) {
            return true;
        }
    }

    return false;
}

fn nameByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '.';
}

fn secretName(name: []const u8) bool {
    var lower_buffer: [128]u8 = undefined;
    if (name.len > lower_buffer.len) {
        return false;
    }

    const lower = std.ascii.lowerString(&lower_buffer, name);
    for (secret_names) |known| {
        if (std.mem.eql(u8, lower, known)) {
            return true;
        }
    }

    for (secret_name_fragments) |fragment| {
        if (std.mem.indexOf(u8, lower, fragment) != null) {
            return true;
        }
    }

    return std.mem.endsWith(u8, lower, "_key") or std.mem.endsWith(u8, lower, "-key");
}

// A count of tokens (`max_tokens = 4096`) is a number; any other secret
// name keeps a value of digits.
fn countsNumbers(name: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(name, "token") == null;
}

// Whether what follows `=` or `:` is a value written out: not empty, not a
// variable, a command substitution or a template, not a boolean, and not a
// number unless `numbers` says a number is a secret too. An authorization
// scheme (`Bearer $TOKEN`) is looked past to its credential.
fn literalValue(rest: []const u8, numbers: bool) bool {
    var index: usize = 0;
    var value = nextWord(rest, &index) orelse return false;
    for ([_][]const u8{ "bearer", "basic", "token", "digest" }) |scheme| {
        if (std.ascii.eqlIgnoreCase(value, scheme)) {
            value = nextWord(rest, &index) orelse return false;
            break;
        }
    }

    if (value.len < min_value_bytes) {
        return false;
    }

    for ([_][]const u8{ "true", "false", "null", "none", "undefined" }) |word| {
        if (std.ascii.eqlIgnoreCase(value, word)) {
            return false;
        }
    }

    if (numbers) {
        return true;
    }

    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and byte != '.' and byte != '_') {
            return true;
        }
    }

    return false;
}

// The next word of a value from `index.*`, past blanks and one opening
// quote; null when it is empty or a placeholder.
fn nextWord(rest: []const u8, index: *usize) ?[]const u8 {
    while (index.* < rest.len and (rest[index.*] == ' ' or rest[index.*] == '\t')) {
        index.* += 1;
    }

    if (index.* < rest.len and (rest[index.*] == '"' or rest[index.*] == '\'')) {
        index.* += 1;
    }

    if (index.* == rest.len or placeholder(rest[index.*])) {
        return null;
    }

    const start = index.*;
    while (index.* < rest.len and !std.ascii.isWhitespace(rest[index.*]) and rest[index.*] != '"' and rest[index.*] != '\'' and rest[index.*] != ',' and rest[index.*] != ';') {
        index.* += 1;
    }

    return rest[start..index.*];
}

// A value that names where the secret comes from instead of holding it.
fn placeholder(byte: u8) bool {
    return std.mem.indexOfScalar(u8, "$<{%[(*", byte) != null;
}

test "the auditor's inline secrets are found" {
    const cases = [_]struct { text: []const u8, kind: Kind }{
        .{ .text = "curl -X POST https://hooks.slack.com/services/T000/B000/XXXXXXXX -d '{}'", .kind = .webhook },
        .{ .text = "TOKEN=abc123def ./notify.sh", .kind = .assignment },
        .{ .text = "GITHUB_PERSONAL_ACCESS_TOKEN=abcdef012345 gh pr list", .kind = .assignment },
        .{ .text = "curl -H 'Authorization: Bearer abcdefghijkl' https://x", .kind = .bearer },
        .{ .text = "curl -H 'x-api-key: 0123456789' https://api", .kind = .assignment },
        .{ .text = "Authorization = \"Basic Zm9vOmJhcg==\"", .kind = .assignment },
        .{ .text = "git clone https://me:hunter22@git.example.com/r.git", .kind = .url_credentials },
        .{ .text = "export GH=ghp_0123456789abcdefghijABCDEFGHIJ", .kind = .token_prefix },
        .{ .text = "\"x-api-key\": \"k-123456\"", .kind = .assignment },
        .{ .text = "      GITHUB_TOKEN: ghx-abcdef", .kind = .assignment },
        .{ .text = "-----BEGIN OPENSSH PRIVATE KEY-----", .kind = .private_key },
        .{ .text = "SLACK=xoxb-1234567890-abcdef", .kind = .token_prefix },
        .{ .text = "key = \"AKIAABCDEFGHIJKLMNOP\"", .kind = .token_prefix },
    };

    for (cases) |case| {
        const finding = find(case.text) orelse {
            std.debug.print("not found: {s}\n", .{case.text});
            return error.TestExpectedFinding;
        };
        try std.testing.expectEqual(case.kind, finding.kind);
    }
}

test "references, numbers and plain prose are not secrets" {
    for ([_][]const u8{
        "TOKEN=$(security find-generic-password -s x -w) ./notify.sh",
        "curl -H \"Authorization: Bearer $TOKEN\" https://x",
        "curl -H 'Authorization: Bearer ${API_TOKEN}' https://x",
        "max_tokens = 4096",
        "\"maxTokens\": 8192",
        "requires_openai_auth = true",
        "api_key = \"\"",
        "https://example.com/path?q=1",
        "ssh://git@github.com/org/repo.git",
        "# Deploy\nRun `make deploy` after review.",
        "\"command\": \"/home/dev/.claude/hooks/notify.sh\"",
        "keybindings: vim",
        "a == b",
    }) |text| {
        if (find(text)) |finding| {
            std.debug.print("false positive ({s}): {s}\n", .{ @tagName(finding.kind), text });
            return error.TestUnexpectedFinding;
        }
    }
}

test "a finding names its line" {
    const finding = find("model = \"m\"\n\n[x]\nsecret = \"abcd\"\n").?;
    try std.testing.expectEqual(@as(u32, 4), finding.line);
    try std.testing.expectEqual(Kind.assignment, finding.kind);
}
