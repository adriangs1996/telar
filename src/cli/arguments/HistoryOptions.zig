const HistoryOptions = @This();
const source_namespace = @import("history.zig");
const core = @import("telar-core");
const std = @import("std");
const Cursor = @import("cursor_support.zig").Cursor;
action: source_namespace.HistoryAction,
import_kind: source_namespace.HistoryImportKind = .auto,
import_file: ?[*:0]const u8 = null,
delete_id: u64 = 0,
before_ms: i64 = 0,
period_days: u16 = 0,
dry_run: bool = false,
assume_yes: bool = false,
query: ?[*:0]const u8 = null,
scope: core.schema.HistoryScope = .global,
scope_value: ?[*:0]const u8 = null,
pane_id: core.schema.PaneId = .invalid,
failed_only: bool = false,
author: core.schema.HistoryAuthorFilter = .all,
limit: u16 = 20,
socket: ?[*:0]const u8 = null,

pub fn parse(args: []const [*:0]const u8) !HistoryOptions {
    if (args.len == 0) {
        return error.MissingHistoryAction;
    }

    const action_text = std.mem.span(args[0]);
    var options: HistoryOptions = if (std.mem.eql(u8, action_text, "list"))
        .{ .action = .list }
    else if (std.mem.eql(u8, action_text, "search")) search: {
        if (args.len < 2) {
            return error.MissingHistoryQuery;
        }

        break :search .{ .action = .search, .query = args[1] };
    } else if (std.mem.eql(u8, action_text, "stats")) .{
        .action = .stats,
    } else if (std.mem.eql(u8, action_text, "show")) show: {
        if (args.len < 2) {
            return error.MissingHistoryId;
        }

        const raw = try std.fmt.parseInt(u64, std.mem.span(args[1]), 10);
        if (raw == 0) {
            return error.InvalidHistoryId;
        }

        break :show .{ .action = .show, .delete_id = raw };
    } else if (std.mem.eql(u8, action_text, "delete")) delete: {
        if (args.len < 2) {
            return error.MissingHistoryId;
        }

        const raw = try std.fmt.parseInt(u64, std.mem.span(args[1]), 10);
        if (raw == 0) {
            return error.InvalidHistoryId;
        }

        break :delete .{ .action = .delete, .delete_id = raw };
    } else if (std.mem.eql(u8, action_text, "prune")) .{
        .action = .prune,
    } else if (std.mem.eql(u8, action_text, "import")) import: {
        var imported: HistoryOptions = .{ .action = .import };
        if (args.len > 1 and args[1][0] != '-') {
            const kind = std.mem.span(args[1]);
            imported.import_kind = if (std.mem.eql(u8, kind, "auto"))
                .auto
            else if (std.mem.eql(u8, kind, "zsh"))
                .zsh
            else if (std.mem.eql(u8, kind, "bash"))
                .bash
            else if (std.mem.eql(u8, kind, "fish"))
                .fish
            else
                return error.UnknownHistoryImportKind;
        }

        break :import imported;
    } else return error.UnknownHistoryAction;

    const index: usize = switch (options.action) {
        .search, .delete, .show => 2,
        .import => if (args.len > 1 and args[1][0] != '-') 2 else 1,
        else => 1,
    };
    var cursor: Cursor = .{ .remaining = args[index..] };
    while (cursor.next()) |argument| {
        const arg = std.mem.span(argument);
        if (std.mem.eql(u8, arg, "--file")) {
            if (options.action != .import) {
                return error.UnknownHistoryOption;
            }
            const value = try cursor.require(error.MissingHistoryFile);

            options.import_file = value;
        } else if (std.mem.eql(u8, arg, "--cwd")) {
            try options.setScope(.cwd, null);
        } else if (std.mem.eql(u8, arg, "--workspace")) {
            const value = try cursor.require(error.MissingWorkspacePath);

            try options.setScope(.workspace, value);
        } else if (std.mem.eql(u8, arg, "--pane")) {
            const value = try cursor.require(error.MissingPaneId);

            const raw = try std.fmt.parseInt(u64, std.mem.span(value), 10);
            options.pane_id = try core.schema.id.pane(raw);
            try options.setScope(.pane, null);
        } else if (std.mem.eql(u8, arg, "--failed")) {
            options.failed_only = true;
        } else if (std.mem.eql(u8, arg, "--period")) {
            if (options.action != .stats) {
                return error.UnknownHistoryOption;
            }
            const value = try cursor.require(error.MissingHistoryPeriod);

            const period = std.mem.span(value);
            options.period_days = if (std.mem.eql(u8, period, "today"))
                1
            else if (std.mem.eql(u8, period, "week"))
                7
            else if (std.mem.eql(u8, period, "month"))
                30
            else if (std.mem.eql(u8, period, "year"))
                365
            else if (std.mem.eql(u8, period, "all"))
                0
            else
                return error.InvalidHistoryPeriod;
        } else if (std.mem.eql(u8, arg, "--before")) {
            if (options.action != .prune) {
                return error.UnknownHistoryOption;
            }
            const value = try cursor.require(error.MissingHistoryBefore);

            options.before_ms = try parseBeforeDate(std.mem.span(value));
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            if (options.action != .prune) {
                return error.UnknownHistoryOption;
            }

            options.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--yes")) {
            if (options.action != .prune) {
                return error.UnknownHistoryOption;
            }

            options.assume_yes = true;
        } else if (std.mem.eql(u8, arg, "--match")) {
            if (options.action != .prune) {
                return error.UnknownHistoryOption;
            }
            const value = try cursor.require(error.MissingHistoryQuery);

            options.query = value;
        } else if (std.mem.eql(u8, arg, "--author")) {
            const value = try cursor.require(error.MissingHistoryAuthor);

            const author = std.mem.span(value);
            options.author = if (std.mem.eql(u8, author, "all"))
                .all
            else if (std.mem.eql(u8, author, "human"))
                .human
            else if (std.mem.eql(u8, author, "agent"))
                .agent
            else
                return error.InvalidHistoryAuthor;
        } else if (std.mem.eql(u8, arg, "--limit")) {
            const value = try cursor.require(error.MissingHistoryLimit);

            options.limit = try std.fmt.parseInt(u16, std.mem.span(value), 10);
            if (options.limit == 0 or options.limit > core.schema.max_history_results) {
                return error.InvalidHistoryLimit;
            }
        } else if (std.mem.eql(u8, arg, "--socket")) {
            const value = try cursor.require(error.MissingSocketPath);
            if (options.socket != null) {
                return error.DuplicateSocketOption;
            }

            options.socket = value;
        } else {
            return error.UnknownHistoryOption;
        }
    }
    return options;
}

/// Parses `--before` as `YYYY-MM-DD` (UTC midnight) or unix seconds.
fn parseBeforeDate(text: []const u8) !i64 {
    if (std.mem.indexOfScalar(u8, text, '-')) |_| {
        var parts = std.mem.splitScalar(u8, text, '-');
        const year = try std.fmt.parseInt(i64, parts.next() orelse return error.InvalidHistoryBefore, 10);
        const month = try std.fmt.parseInt(i64, parts.next() orelse return error.InvalidHistoryBefore, 10);
        const day = try std.fmt.parseInt(i64, parts.next() orelse return error.InvalidHistoryBefore, 10);
        if (parts.next() != null or year < 1970 or month < 1 or month > 12 or day < 1 or day > 31) {
            return error.InvalidHistoryBefore;
        }

        const epoch_days = daysFromCivil(year, month, day);
        return epoch_days * 86_400_000;
    }

    const seconds = try std.fmt.parseInt(i64, text, 10);
    if (seconds <= 0) {
        return error.InvalidHistoryBefore;
    }

    return seconds * 1_000;
}

/// Howard Hinnant's days-from-civil algorithm.
fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(month + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146_097 + doe - 719_468;
}

fn setScope(options: *HistoryOptions, scope: core.schema.HistoryScope, value: ?[*:0]const u8) !void {
    if (options.scope != .global) {
        return error.ConflictingHistoryScopes;
    }

    options.scope = scope;
    options.scope_value = value;
}
