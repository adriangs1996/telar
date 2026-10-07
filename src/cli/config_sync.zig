//! The configuration step of `telar machine setup`:
//! the non-secret configuration of every agent the person has here goes to
//! the machine. Only allowlisted paths are read (`config_allowlist`), never
//! a denied one, even through a symlink. Before anything leaves, secret keys
//! and MCP servers are dropped (`config_filter`), this home's paths become
//! the machine's, telar's hooks are written for the machine's telar, and a
//! hook whose program is not on the machine is left out. A file a hook or
//! the status line names inside an agent's directory travels with it.
//! The machine writes what differs through `telar machine receive-config`.
const std = @import("std");
const MachinePlatform = @import("MachinePlatform.zig");
const SetupReport = @import("SetupReport.zig");
const config_allowlist = @import("config_allowlist.zig");
const ConfigEntry = @import("ConfigEntry.zig");
const core = @import("telar-core");
const config_filter = @import("config_filter.zig");
const config_receive = @import("config_receive.zig");
const config_secrets = @import("config_secrets.zig");
const integration_support = @import("integration_support.zig");
const remote_shell = @import("remote_shell.zig");

const Agent = config_allowlist.Agent;
const Format = ConfigEntry.Format;

/// Directories below an allowlisted one the walk enters, at most: plugin
/// marketplaces nest skills and their references a dozen levels down.
const max_depth = 16;
/// Up to 16 MiB of configuration over a slow link.
const send_timeout_s = 600;
const query_timeout_s = 60;

/// One file on its way to the machine.
const StagedFile = struct {
    /// Relative to the machine's home.
    remote_path: []const u8,
    bytes: []const u8,
    mode: config_receive.Mode,
    format: Format,
    hooks_agent: ?Agent,
    json: ?std.json.Value = null,
};

/// A directory the sync reads under: an agent's configuration directory or
/// the shared skills, with where it really is here once symlinks resolve.
const SyncRoot = struct {
    /// Relative to the home on both sides, as `rootFor` names it.
    remote: []const u8,
    /// The real path of this machine's copy.
    real: []const u8,
};

/// Every file one sync sends, and what it left out and why.
const Staging = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    local_home: []const u8,
    remote_home: []const u8,
    files: std.ArrayList(StagedFile) = .empty,
    total_bytes: usize = 0,
    /// One line per path left here, for the report.
    left: std.ArrayList([]const u8) = .empty,
    /// Where each wanted agent keeps its configuration here.
    local_roots: std.EnumArray(Agent, ?[]const u8) = .initFill(null),
    /// Every root read, real paths resolved.
    roots: std.ArrayList(SyncRoot) = .empty,

    fn leave(self: *Staging, comptime format: []const u8, arguments: anytype) !void {
        try self.left.append(self.arena, try std.fmt.allocPrint(self.arena, format, arguments));
    }

    fn staged(self: *const Staging, remote_path: []const u8) bool {
        for (self.files.items) |*file| {
            if (std.mem.eql(u8, file.remote_path, remote_path)) {
                return true;
            }
        }

        return false;
    }

    // Records a root's real path; false when it does not exist here.
    fn addRoot(self: *Staging, remote: []const u8, local: []const u8) !bool {
        var real_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const real_len = std.Io.Dir.realPathFileAbsolute(self.io, local, &real_buffer) catch return false;
        try self.roots.append(self.arena, .{
            .remote = remote,
            .real = try self.arena.dupe(u8, real_buffer[0..real_len]),
        });
        return true;
    }

    /// Whether `real`, where `remote_path` really is here, lies inside the
    /// real directory of the root `remote_path` is synced under. A root
    /// that is a symlink (`~/.claude` into a dotfiles checkout) is followed
    /// once, when it is recorded; nothing below it may leave it.
    fn inside(self: *const Staging, remote_path: []const u8, real: []const u8) bool {
        for (self.roots.items) |*root| {
            if (!below(remote_path, root.remote)) {
                continue;
            }

            return std.mem.eql(u8, real, root.real) or below(real, root.real);
        }

        return false;
    }

    // Reads one allowlisted file, refusing a credential by its name, a path
    // whose real location is outside its root, a hard link and anything
    // past the bounds.
    fn addFile(self: *Staging, local_path: []const u8, remote_path: []const u8, format: Format, hooks_agent: ?Agent) !void {
        if (self.staged(remote_path)) {
            return;
        }

        var real_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const real_len = std.Io.Dir.realPathFileAbsolute(self.io, local_path, &real_buffer) catch return;
        const real = real_buffer[0..real_len];
        if (config_allowlist.denied(local_path) or config_allowlist.denied(real) or !config_allowlist.acceptable(remote_path)) {
            return self.leave("{s}: never sent", .{remote_path});
        }

        if (!self.inside(remote_path, real)) {
            return self.leave("{s}: leads outside its agent's directory, not sent", .{remote_path});
        }

        // A FIFO would block the open, so the kind is checked first; the
        // bytes then come from the file whose metadata is checked.
        const kind = std.Io.Dir.cwd().statFile(self.io, real, .{ .follow_symlinks = false }) catch return;
        if (kind.kind != .file) {
            return;
        }

        const file = std.Io.Dir.cwd().openFile(self.io, real, .{
            .follow_symlinks = false,
            .allow_directory = false,
        }) catch return;
        defer file.close(self.io);

        const stat = file.stat(self.io) catch return;
        if (stat.kind != .file) {
            return;
        }

        if (stat.nlink > 1) {
            return self.leave("{s}: has another hard link, which could be any file; not sent", .{remote_path});
        }

        if (stat.size > config_receive.max_file_bytes) {
            return self.leave("{s}: larger than {d} KiB, not sent", .{ remote_path, config_receive.max_file_bytes / 1024 });
        }

        if (self.files.items.len == config_receive.max_files or self.total_bytes + stat.size > config_receive.max_total_bytes) {
            return self.leave("{s}: the sync is full, not sent", .{remote_path});
        }

        var reader = file.reader(self.io, &.{});
        const bytes = reader.interface.allocRemaining(self.arena, .limited(config_receive.max_file_bytes + 1)) catch |err| switch (err) {
            error.StreamTooLong => return self.leave("{s}: larger than {d} KiB, not sent", .{ remote_path, config_receive.max_file_bytes / 1024 }),
            error.OutOfMemory => return error.OutOfMemory,
            error.ReadFailed => return,
        };
        self.total_bytes += bytes.len;
        try self.files.append(self.arena, .{
            .remote_path = try self.arena.dupe(u8, remote_path),
            .bytes = bytes,
            .mode = if (stat.permissions.toMode() & 0o111 != 0) .executable else .regular,
            .format = format,
            .hooks_agent = hooks_agent,
        });
    }

    // Walks an allowlisted directory: hidden entries stay, a directory whose
    // real path leaves its root is skipped, and depth is bounded, so a
    // cycle ends.
    fn addTree(self: *Staging, local_dir: []const u8, remote_dir: []const u8, depth: u8) !void {
        if (config_allowlist.telarOwned(remote_dir)) {
            return;
        }

        if (depth > max_depth) {
            return self.leave("{s}/: deeper than {d} directories, not sent", .{ remote_dir, max_depth });
        }

        var real_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const real_len = std.Io.Dir.realPathFileAbsolute(self.io, local_dir, &real_buffer) catch return;
        if (!self.inside(remote_dir, real_buffer[0..real_len])) {
            return self.leave("{s}/: leads outside its agent's directory, not sent", .{remote_dir});
        }

        var dir = std.Io.Dir.cwd().openDir(self.io, local_dir, .{ .iterate = true }) catch return;
        defer dir.close(self.io);

        var iterator = dir.iterate();
        while (try iterator.next(self.io)) |entry| {
            if (entry.name.len == 0 or entry.name[0] == '.') {
                continue;
            }

            const local_path = try std.fmt.allocPrint(self.arena, "{s}/{s}", .{ local_dir, entry.name });
            const remote_path = try std.fmt.allocPrint(self.arena, "{s}/{s}", .{ remote_dir, entry.name });
            if (config_allowlist.telarOwned(remote_path)) {
                continue;
            }

            const kind = if (entry.kind == .sym_link) targetKind(self.io, local_path) else entry.kind;
            switch (kind) {
                .directory => try self.addTree(local_path, remote_path, depth + 1),
                .file => try self.addFile(local_path, remote_path, .text, null),
                else => {},
            }
        }
    }

    // Keeps `bytes` of the file at `index`, or holds the file back when it
    // looks like it holds a secret; false when it was held back.
    fn keepUnlessSecret(self: *Staging, index: usize, bytes: []const u8) !bool {
        const file = &self.files.items[index];
        if (config_secrets.find(bytes)) |finding| {
            try self.leave("{s}: held back, line {d} holds what looks like {s}; review it and sync again", .{
                file.remote_path,
                finding.line,
                finding.kind.describe(),
            });
            return false;
        }

        file.bytes = bytes;
        return true;
    }
};

// Whether `path` lies below the directory `parent`.
fn below(path: []const u8, parent: []const u8) bool {
    return path.len > parent.len and std.mem.startsWith(u8, path, parent) and path[parent.len] == '/';
}

fn targetKind(io: std.Io, path: []const u8) std.Io.File.Kind {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return .unknown;
    return stat.kind;
}

/// Sends the configuration of the `wanted` agents to the machine and
/// reports what it wrote, what it left here and why. A failure, SSH's
/// included, fails this step and no other.
///
/// ```zig
/// try config_sync.run(process_init, &report, "dev@box", &platform, wanted);
/// ```
pub fn run(init: std.process.Init, report: *SetupReport, destination: []const u8, platform: *const MachinePlatform, wanted: std.EnumSet(Agent)) !void {
    if (wanted.count() == 0) {
        try report.end(.configuration, .skipped, "no agent here to take configuration from", .{});
        return;
    }

    sync(init, report, destination, platform, wanted) catch |err| {
        try report.end(.configuration, .failed, "{s}; nothing more was written there", .{@errorName(err)});
    };
}

fn sync(init: std.process.Init, report: *SetupReport, destination: []const u8, platform: *const MachinePlatform, wanted: std.EnumSet(Agent)) !void {
    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();

    var staging: Staging = .{
        .arena = arena_state.allocator(),
        .io = init.io,
        .local_home = std.process.Environ.getPosix(init.minimal.environ, "HOME") orelse return error.HomeUnavailable,
        .remote_home = platform.home.slice(),
    };
    try collect(&staging, init.minimal.environ, wanted);
    try transform(&staging, platform.target.slice());
    const existing = try queryPaths(init, destination, &staging);
    try pruneHooks(&staging, existing);
    try serialize(&staging);

    const stream = try writeStream(&staging);
    var command_buffer: [512]u8 = undefined;
    const command = try std.fmt.bufPrint(&command_buffer, "{s} machine receive-config", .{platform.target.slice()});
    var result = try remote_shell.runWithBytes(init, destination, command, stream, send_timeout_s);
    defer result.deinit(init.gpa);
    if (!result.succeeded()) {
        try report.end(.configuration, .failed, "the machine refused the sync: {s}", .{result.errorLine()});
        return;
    }

    var written: usize = 0;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, try result.wholeStdout(), "\n"), '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "written ")) {
            written += 1;
            try report.note(.configuration, "{s}", .{line});
        } else if (std.mem.startsWith(u8, line, "refused ")) {
            try report.note(.configuration, "left alone there: {s}", .{line["refused ".len..]});
        }
    }

    for (staging.left.items) |line| {
        try report.note(.configuration, "{s}", .{line});
    }

    const status: SetupReport.Status = if (written != 0) .changed else .ok;
    try report.end(.configuration, status, "{d} of {d} files written; credentials, sessions and history stay here", .{ written, staging.files.items.len });
}

// Stages every allowlisted path of every wanted agent, and the skills the
// agents other than Claude Code share.
fn collect(staging: *Staging, environ: std.process.Environ, wanted: std.EnumSet(Agent)) !void {
    var iterator = wanted.iterator();
    while (iterator.next()) |agent| {
        const root = config_allowlist.rootFor(agent);
        const local_root = try localRoot(staging, environ, root);
        staging.local_roots.set(agent, local_root);
        if (!try staging.addRoot(root.directory, local_root)) {
            continue;
        }

        for (config_allowlist.entriesFor(agent)) |entry| {
            const local_path = try std.fmt.allocPrint(staging.arena, "{s}/{s}", .{ local_root, entry.path });
            const remote_path = try std.fmt.allocPrint(staging.arena, "{s}/{s}", .{ root.directory, entry.path });
            switch (entry.kind) {
                .file => try staging.addFile(local_path, remote_path, entry.format, if (entry.hooks) agent else null),
                .directory => try staging.addTree(local_path, remote_path, 0),
            }
        }
    }

    if (wanted.contains(.codex) or wanted.contains(.opencode) or wanted.contains(.cursor)) {
        const local_path = try std.fmt.allocPrint(staging.arena, "{s}/{s}", .{ staging.local_home, config_allowlist.shared_skills });
        if (try staging.addRoot(config_allowlist.shared_skills, local_path)) {
            try staging.addTree(local_path, config_allowlist.shared_skills, 0);
        }
    }
}

fn localRoot(staging: *Staging, environ: std.process.Environ, root: core.AgentConfigRoot) ![]const u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const override = if (root.environment) |name| std.process.Environ.getPosix(environ, name) else null;
    const resolved = root.resolve(override, staging.local_home, &buffer) orelse return error.HomeUnavailable;
    return staging.arena.dupe(u8, resolved);
}

// Filters and rewrites every staged file, and holds back a text file that
// looks like it holds a secret. JSON stays parsed until hooks are pruned;
// files its commands name inside an agent's directory join the sync.
fn transform(staging: *Staging, telar_path: []const u8) !void {
    var index: usize = 0;
    while (index < staging.files.items.len) {
        if (try transformOne(staging, index, telar_path)) {
            index += 1;
        } else {
            _ = staging.files.orderedRemove(index);
        }
    }
}

// Transforms the file at `index`; false when it stays here.
fn transformOne(staging: *Staging, index: usize, telar_path: []const u8) !bool {
    const file = staging.files.items[index];
    var dropped: std.ArrayList([]const u8) = .empty;
    switch (file.format) {
        .text => {
            const bytes = try config_filter.rewriteHome(staging.arena, file.bytes, staging.local_home, staging.remote_home);
            if (!try staging.keepUnlessSecret(index, bytes)) {
                return false;
            }
        },
        .toml => {
            const filtered = try config_filter.filterToml(staging.arena, file.bytes, staging.arena, &dropped);
            const bytes = try config_filter.rewriteHome(staging.arena, filtered, staging.local_home, staging.remote_home);
            if (!try staging.keepUnlessSecret(index, bytes)) {
                return false;
            }
        },
        .json => {
            const plain = config_filter.stripJsonc(staging.arena, file.bytes) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.UnterminatedComment => {
                    try staging.leave("{s}: not valid JSON here, not sent", .{file.remote_path});
                    return false;
                },
            };

            var value = std.json.parseFromSliceLeaky(std.json.Value, staging.arena, plain, .{}) catch {
                try staging.leave("{s}: not valid JSON here, not sent", .{file.remote_path});
                return false;
            };

            try config_filter.dropSecrets(staging.arena, &value, &dropped);
            try bringCommandFiles(staging, value);
            try rewriteStrings(staging, &value);
            if (file.hooks_agent) |agent| {
                _ = try integration_support.placeHooks(staging.arena, &value, agent, telar_path);
            }

            // Staging more files may have moved the list.
            staging.files.items[index].json = value;
        },
    }

    if (dropped.items.len != 0) {
        const joined = try std.mem.join(staging.arena, ", ", dropped.items);
        try staging.leave("{s}: left out {s}", .{ file.remote_path, joined });
    }

    return true;
}

// Writes each JSON file out as `integration install` writes settings, once
// its hooks are pruned, and holds back one that still looks like it holds a
// secret: a hook's command with a token in it.
fn serialize(staging: *Staging) !void {
    var index: usize = 0;
    while (index < staging.files.items.len) {
        const json = staging.files.items[index].json orelse {
            index += 1;
            continue;
        };

        const bytes = try std.fmt.allocPrint(staging.arena, "{f}\n", .{std.json.fmt(json, .{ .whitespace = .indent_2 })});
        if (try staging.keepUnlessSecret(index, bytes)) {
            staging.files.items[index].json = null;
            index += 1;
        } else {
            _ = staging.files.orderedRemove(index);
        }
    }
}

// Stages the files a hook or the status line names inside a wanted agent's
// directory here, so the command finds them there.
fn bringCommandFiles(staging: *Staging, value: std.json.Value) !void {
    var commands: std.ArrayList([]const u8) = .empty;
    try collectCommands(staging.arena, value, &commands, false);
    for (commands.items) |command| {
        var tokens = std.mem.tokenizeAny(u8, command, " \t\n;&|()'\"=");
        while (tokens.next()) |token| {
            const local = try localPath(staging, token) orelse continue;
            for (std.enums.values(Agent)) |agent| {
                const root = staging.local_roots.get(agent) orelse continue;
                if (!std.mem.startsWith(u8, local, root) or local.len <= root.len or local[root.len] != '/') {
                    continue;
                }

                const remote_path = try std.fmt.allocPrint(staging.arena, "{s}{s}", .{ config_allowlist.rootFor(agent).directory, local[root.len..] });
                try staging.addFile(local, remote_path, .text, null);
            }
        }
    }
}

// A command word as a path here: this home written out, `~/` or `$HOME/`.
fn localPath(staging: *Staging, token: []const u8) !?[]const u8 {
    for ([_][]const u8{ "~/", "$HOME/", "${HOME}/" }) |prefix| {
        if (std.mem.startsWith(u8, token, prefix)) {
            return try std.fmt.allocPrint(staging.arena, "{s}/{s}", .{ staging.local_home, token[prefix.len..] });
        }
    }

    if (std.mem.startsWith(u8, token, staging.local_home) and token.len > staging.local_home.len and token[staging.local_home.len] == '/') {
        return token;
    }

    return null;
}

// Collects every `command` string under `hooks` or `statusLine`.
fn collectCommands(arena: std.mem.Allocator, value: std.json.Value, commands: *std.ArrayList([]const u8), inside: bool) !void {
    switch (value) {
        .object => |object| {
            if (inside) {
                if (object.get("command")) |command| {
                    if (command == .string) {
                        try commands.append(arena, command.string);
                    }
                }
            }

            var iterator = object.iterator();
            while (iterator.next()) |field| {
                const enters = inside or std.mem.eql(u8, field.key_ptr.*, "hooks") or std.mem.eql(u8, field.key_ptr.*, "statusLine");
                try collectCommands(arena, field.value_ptr.*, commands, enters);
            }
        },
        .array => |array| {
            for (array.items) |item| {
                try collectCommands(arena, item, commands, inside);
            }
        },
        else => {},
    }
}

fn rewriteStrings(staging: *Staging, value: *std.json.Value) !void {
    switch (value.*) {
        .string => |text| value.* = .{ .string = try config_filter.rewriteHome(staging.arena, text, staging.local_home, staging.remote_home) },
        .object => |*object| {
            for (object.values()) |*item| {
                try rewriteStrings(staging, item);
            }
        },
        .array => |*array| {
            for (array.items) |*item| {
                try rewriteStrings(staging, item);
            }
        },
        else => {},
    }
}

// Asks the machine which absolute paths the synced commands name exist
// there, besides what the sync brings.
fn queryPaths(init: std.process.Init, destination: []const u8, staging: *Staging) !std.StringHashMapUnmanaged(void) {
    var existing: std.StringHashMapUnmanaged(void) = .empty;
    var script: std.Io.Writer.Allocating = .init(staging.arena);
    try script.writer.writeAll("while IFS= read -r path; do if [ -e \"$path\" ]; then printf '%s\\n' \"$path\"; fi; done <<'TELAR_PATHS'\n");
    var asked: usize = 0;
    for (staging.files.items) |*file| {
        const json = file.json orelse continue;
        var commands: std.ArrayList([]const u8) = .empty;
        try collectCommands(staging.arena, json, &commands, false);
        for (commands.items) |command| {
            var paths = requiredPaths(staging, command);
            while (paths.next()) |path| {
                if (std.mem.indexOfScalar(u8, path, '\n') == null and !std.mem.eql(u8, path, "TELAR_PATHS")) {
                    try script.writer.print("{s}\n", .{path});
                    asked += 1;
                }
            }
        }
    }

    if (asked == 0) {
        return existing;
    }

    try script.writer.writeAll("TELAR_PATHS\n");
    var result = try remote_shell.runScript(init, destination, script.written(), query_timeout_s);
    defer result.deinit(init.gpa);
    // An unanswered question is no answer: every hook would look missing
    // and be dropped from what the machine gets.
    if (!result.succeeded()) {
        return error.MachinePathsUnreadable;
    }

    var lines = std.mem.splitScalar(u8, try result.wholeStdout(), '\n');
    while (lines.next()) |line| {
        if (line.len != 0) {
            try existing.put(staging.arena, try staging.arena.dupe(u8, line), {});
        }
    }

    return existing;
}

/// The absolute paths a rewritten command runs or reads on the machine.
const RequiredPaths = struct {
    tokens: std.mem.TokenIterator(u8, .any),
    remote_home: []const u8,
    // SAFETY: next formats expanded paths before returning their slice; absolute paths borrow tokens instead.
    buffer: [std.fs.max_path_bytes]u8 = undefined,

    fn next(self: *RequiredPaths) ?[]const u8 {
        while (self.tokens.next()) |token| {
            if (std.mem.startsWith(u8, token, "/")) {
                return token;
            }

            for ([_][]const u8{ "~/", "$HOME/", "${HOME}/" }) |prefix| {
                if (std.mem.startsWith(u8, token, prefix)) {
                    return std.fmt.bufPrint(&self.buffer, "{s}/{s}", .{ self.remote_home, token[prefix.len..] }) catch null;
                }
            }
        }

        return null;
    }
};

fn requiredPaths(staging: *const Staging, command: []const u8) RequiredPaths {
    return .{
        .tokens = std.mem.tokenizeAny(u8, command, " \t\n;&|()'\"="),
        .remote_home = staging.remote_home,
    };
}

// Whether every path the command names is on the machine or on its way.
fn commandRuns(staging: *const Staging, existing: *const std.StringHashMapUnmanaged(void), command: []const u8) bool {
    if (integration_support.telarCommand(command)) {
        return true;
    }

    var paths = requiredPaths(staging, command);
    while (paths.next()) |path| {
        if (existing.contains(path)) {
            continue;
        }

        const home_prefix_len = staging.remote_home.len + 1;
        const under_home = std.mem.startsWith(u8, path, staging.remote_home) and path.len > home_prefix_len and path[staging.remote_home.len] == '/';
        if (under_home and staging.staged(path[home_prefix_len..])) {
            continue;
        }

        return false;
    }

    return true;
}

// Leaves out every hook, and the status line, whose program is not on the
// machine, then drops what that emptied.
fn pruneHooks(staging: *Staging, existing: std.StringHashMapUnmanaged(void)) !void {
    for (staging.files.items) |*file| {
        if (file.json == null or file.json.? != .object) {
            continue;
        }

        const root = &file.json.?.object;
        if (root.getPtr("statusLine")) |status_line| {
            if (!try keepCommands(staging, &existing, status_line, file.remote_path)) {
                _ = root.orderedRemove("statusLine");
            }
        }

        if (root.getPtr("hooks")) |hooks| {
            _ = try keepCommands(staging, &existing, hooks, file.remote_path);
        }
    }
}

// Removes from `value` every command object that cannot run there; returns
// false when `value` itself is such an object or was emptied by it.
fn keepCommands(staging: *Staging, existing: *const std.StringHashMapUnmanaged(void), value: *std.json.Value, file_path: []const u8) !bool {
    switch (value.*) {
        .object => |*object| {
            if (object.get("command")) |command| {
                if (command == .string and !commandRuns(staging, existing, command.string)) {
                    try staging.leave("{s}: left out `{s}`, whose program is not there", .{ file_path, command.string });
                    return false;
                }
            }

            var index: usize = 0;
            while (index < object.count()) {
                const child = &object.values()[index];
                const was_container = child.* == .array or child.* == .object;
                const had_items = switch (child.*) {
                    .array => |array| array.items.len != 0,
                    .object => |inner| inner.count() != 0,
                    else => false,
                };
                if (was_container and had_items and !try keepCommands(staging, existing, child, file_path)) {
                    object.orderedRemoveAt(index);
                    continue;
                }

                index += 1;
            }

            return object.count() != 0;
        },
        .array => |*array| {
            const had_items = array.items.len != 0;
            var index: usize = 0;
            while (index < array.items.len) {
                const item = &array.items[index];
                if ((item.* == .object or item.* == .array) and !try keepCommands(staging, existing, item, file_path)) {
                    _ = array.orderedRemove(index);
                    continue;
                }

                index += 1;
            }

            return !had_items or array.items.len != 0;
        },
        else => return true,
    }
}

// The stream `receive-config` reads, once `serialize` wrote out the JSON.
fn writeStream(staging: *Staging) ![]const u8 {
    var stream: std.Io.Writer.Allocating = .init(staging.arena);
    try stream.writer.writeAll(config_receive.stream_header ++ "\n");
    for (staging.files.items) |*file| {
        const bytes = file.bytes;
        try stream.writer.print("file {s} {d} {s}\n", .{
            if (file.mode == .executable) "755" else "644",
            bytes.len,
            file.remote_path,
        });
        try stream.writer.writeAll(bytes);
        try stream.writer.writeByte('\n');
    }

    try stream.writer.writeAll("end\n");
    return stream.written();
}
