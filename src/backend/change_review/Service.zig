//! Canonical editions and comments. Every method doing work runs on observation workers.
const std = @import("std");
const core = @import("telar-core");
const Context = @import("Context.zig");
const Edition = @import("Edition.zig");
const Group = @import("Group.zig");
const Sample = @import("Sample.zig");
const Operation = @import("operation.zig").Operation;
const Result = @import("Result.zig");
const ProviderPatch = @import("ProviderPatch.zig");
const storage = @import("storage.zig");
const StorageInput = @import("StorageInput.zig");
const Service = @This();
const SampleInput = @import("SampleInput.zig");
const QueryInput = @import("QueryInput.zig");
const Input = @import("Input.zig");
const Append = @import("Append.zig");
const sample_diff = @import("sample_diff.zig");
const Activation = @import("Activation.zig");
const ArchivedQuery = @import("ArchivedQuery.zig");

pub const group_capacity = 32;
pub const sample_expiry_ms = 10 * 60 * 1000;
gpa: std.mem.Allocator,
directory: []const u8,
disk_bytes: usize = 0,
disk_initialized: bool = false,
mutex: std.Io.Mutex = .init,
groups: [group_capacity]?*Group = @splat(null),
dropped: std.atomic.Value(u64) = .init(0),

pub fn init(gpa: std.mem.Allocator, directory: []const u8) !*Service {
    const self = try gpa.create(Service);
    errdefer gpa.destroy(self);
    self.* = .{ .gpa = gpa, .directory = try gpa.dupe(u8, directory) };
    return self;
}

/// All actors must join before releasing canonical review storage.
/// Example: `service.deinit();`.
pub fn deinit(self: *Service) void {
    for (self.groups) |group| {
        if (group) |value| {
            value.deinit(self.gpa);
            self.gpa.destroy(value);
        }
    }
    const gpa = self.gpa;
    gpa.free(self.directory);
    gpa.destroy(self);
}

pub fn execute(self: *Service, io: std.Io, input: Input) !*Result {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    const group = try self.loadGroup(io, input.context);
    const operation = input.operation;
    if (operation == .sample) {
        const prior_count = group.total;
        self.sample(io, .{ .group = group, .value = operation.sample }) catch |err| {
            _ = self.dropped.fetchAdd(1, .monotonic);
            return err;
        };
        const result = try Result.init(self.gpa);
        errdefer result.deinit();
        result.changed_edition = if (group.total > prior_count) group.total else 0;
        result.len = (try core.encodeRequestCompleted(result.bytes, .{ .request_id = operation.sample.request_id })).len;
        return result;
    }
    const query: core.QueryChangeReview = switch (operation) {
        .query => |value| blk: {
            var owned = value;
            owned.session = input.context.sessionSlice();
            break :blk owned;
        },
        .command => |value| .{ .request_id = value.request_id, .pane_id = value.pane_id, .pane_generation = value.pane_generation, .session = input.context.sessionSlice(), .edition_id = if (value.action == .ack_feedback and value.edition_id == 0) value.feedback_id else value.edition_id },
        .sample => unreachable,
    };
    if (operation == .command and operation.command.action == .feedback) {
        for (group.editions[0..group.count]) |entry| {
            if (entry.?.delivery == .pending) {
                return self.encodeResult(.{ .group = group, .edition = entry.?, .query = query });
            }
        }
        return self.empty(query);
    }
    const selected = if (query.edition_id == 0) group.total else query.edition_id;
    if (selected == 0) {
        return self.empty(query);
    }
    if (selected > group.total) {
        return error.EditionNotFound;
    }
    var index: ?usize = null;
    for (group.editions[0..group.count], 0..) |entry, at| {
        if (entry.?.id == selected) {
            index = at;
            break;
        }
    }
    if (index == null) {
        const archived = try self.loadArchived(io, .{ .group = group, .id = selected });
        if (operation == .query) {
            defer self.gpa.destroy(archived);
            return self.encodeResult(.{ .group = group, .edition = archived, .query = query });
        }
        self.activate(io, .{ .group = group, .edition = archived }) catch |err| {
            self.gpa.destroy(archived);
            return err;
        };
        index = group.count - 1;
    }
    const at = index.?;
    if (operation == .command) {
        const command = operation.command;
        const prior = group.editions[at].?;
        const next = try self.gpa.create(Edition);
        errdefer self.gpa.destroy(next);
        next.* = prior.*;
        if (command.action == .ack_feedback) {
            if (command.feedback_id != next.id) {
                return error.InvalidFeedback;
            }
            if (next.delivery == .idle) {
                return error.InvalidFeedback;
            }
            if (next.delivery == .pending) {
                next.delivery = .delivered;
                next.revision += 1;
            }
        } else {
            try next.apply(command);
        }
        group.editions[at] = next;
        _ = storage.save(self.storageInput(io), group) catch |err| {
            group.editions[at] = prior;
            return err;
        };
        self.gpa.destroy(prior);
    }
    return self.encodeResult(.{ .group = group, .edition = group.editions[at].?, .query = query });
}

/// Loads the durable discovery marker on an observation worker, without encoding a diff.
/// Example: `const latest = try service.latestEdition(io, context);`.
pub fn latestEdition(self: *Service, io: std.Io, context: Context) !u64 {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    for (self.groups) |entry| {
        const group = entry orelse continue;
        if (group.context.provider == context.provider and std.mem.eql(u8, group.context.sessionSlice(), context.sessionSlice())) {
            return group.total;
        }
    }

    return (try self.loadGroup(io, context)).total;
}

/// The provider worker passes only complete official patches, before transcript eviction.
/// Example: `try service.recordProvider(io, record);`.
pub fn recordProvider(self: *Service, io: std.Io, record: ProviderPatch) !u64 {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    const group = try self.loadGroup(io, record.context);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(record.turn);
    hasher.update(&.{0});
    hasher.update(record.item);
    const identity = hasher.finalResult();
    for (group.records[0..group.total], 0..) |existing, index| {
        if (std.mem.eql(u8, &existing.identity, &identity)) {
            const id: u64 = index + 1;
            for (group.editions[0..group.count]) |entry| {
                if (entry.?.id == id and !std.mem.eql(u8, entry.?.text(), record.patch)) {
                    return error.ProviderPatchChanged;
                }
            }
            return id;
        }
    }
    return self.append(io, .{ .group = group, .identity = identity, .source = .provider_patch, .patch = record.patch });
}

fn loadGroup(self: *Service, io: std.Io, context: Context) !*Group {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(@tagName(context.provider));
    hash.update(&.{0});
    hash.update(context.sessionSlice());
    const key = std.fmt.bytesToHex(hash.finalResult(), .lower);
    var free: ?usize = null;
    for (self.groups, 0..) |entry, index| {
        if (entry) |existing| {
            if (std.mem.eql(u8, &key, &existing.key)) {
                if (!std.meta.eql(existing.context.pane, context.pane)) {
                    for (&existing.samples) |*pending| {
                        if (pending.*) |value| {
                            self.gpa.destroy(value);
                            pending.* = null;
                        }
                    }
                }
                existing.context = context;
                return existing;
            }
        } else if (free == null) {
            free = index;
        }
    }
    if (free == null) {
        const now: i64 = @intCast(std.Io.Timestamp.now(io, .awake).toMilliseconds());
        for (&self.groups, 0..) |*entry, index| {
            const candidate = entry.*.?;
            var pending = false;
            for (&candidate.samples) |*sample_value| {
                if (sample_value.*) |value| {
                    if (now - value.created_ms >= sample_expiry_ms) {
                        self.gpa.destroy(value);
                        sample_value.* = null;
                    } else {
                        pending = true;
                    }
                }
            }
            if (!pending) {
                candidate.deinit(self.gpa);
                self.gpa.destroy(candidate);
                entry.* = null;
                free = index;
                break;
            }
        }
    }
    const slot = free orelse return error.ReviewCapacity;
    try storage.ensure(io, self.directory);
    if (!self.disk_initialized) {
        self.disk_bytes = try storage.diskUsage(io, self.directory);
        self.disk_initialized = true;
    }
    const created = try self.gpa.create(Group);
    errdefer self.gpa.destroy(created);
    created.* = .{ .key = key, .context = context };
    errdefer created.deinit(self.gpa);
    try storage.load(self.storageInput(io), created);
    self.groups[slot] = created;
    return created;
}

fn sample(self: *Service, io: std.Io, input: SampleInput) !void {
    const group_value = input.group;
    const value = input.value;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(value.tool_call_id);
    hash.update(&.{0});
    hash.update(value.path);
    const identity = hash.finalResult();
    for (group_value.records[0..group_value.total]) |entry| {
        if (std.mem.eql(u8, &entry.identity, &identity)) {
            return;
        }
    }
    const now: i64 = @intCast(std.Io.Timestamp.now(io, .awake).toMilliseconds());
    var vacant: ?usize = null;
    var found: ?usize = null;
    for (&group_value.samples, 0..) |*entry, index| {
        if (entry.*) |pending| {
            if (now - pending.created_ms >= sample_expiry_ms) {
                self.gpa.destroy(pending);
                entry.* = null;
            } else if (std.mem.eql(u8, &pending.identity, &identity)) {
                found = index;
            }
        }
        if (entry.* == null and vacant == null) {
            vacant = index;
        }
    }
    if (value.phase == .before) {
        if (found != null) {
            return;
        }
        const at = vacant orelse return error.ReviewCapacity;
        const owned = try self.gpa.create(Sample);
        owned.* = Sample.init(value, identity, now);
        group_value.samples[at] = owned;
        return;
    }
    const at = found orelse return error.MissingReviewBaseline;
    const before = group_value.samples[at].?;
    defer {
        group_value.samples[at] = null;
        self.gpa.destroy(before);
    }
    if (before.exists == value.exists and std.mem.eql(u8, before.content[0..before.content_len], value.content)) {
        return;
    }
    const patch = try sample_diff.create(.{ .io = io, .gpa = self.gpa, .directory = self.directory }, .{ .before = before, .after = value });
    defer self.gpa.free(patch);
    _ = try self.append(io, .{ .group = group_value, .identity = identity, .source = .observed_snapshot, .patch = patch });
}

fn append(self: *Service, io: std.Io, input: Append) !u64 {
    const group_value = input.group;
    if (group_value.total == Group.archive_capacity) {
        return error.ReviewCapacity;
    }
    const edition = try self.gpa.create(Edition);
    errdefer self.gpa.destroy(edition);
    edition.* = .{ .id = @as(u64, group_value.total) + 1, .identity = input.identity, .source = input.source };
    try edition.setPatch(input.patch);
    if (group_value.count == Group.capacity) {
        try self.evict(io, group_value);
    }
    group_value.records[group_value.total] = .{ .identity = input.identity };
    group_value.total += 1;
    group_value.editions[group_value.count] = edition;
    group_value.count += 1;
    _ = storage.save(self.storageInput(io), group_value) catch |err| {
        group_value.count -= 1;
        group_value.total -= 1;
        group_value.editions[group_value.count] = null;
        return err;
    };
    return edition.id;
}

fn evict(self: *Service, io: std.Io, group_value: *Group) !void {
    var index: ?usize = null;
    for (group_value.editions[0..group_value.count], 0..) |entry, at| {
        const edition = entry.?;
        if (edition.comment_count != 0 and edition.delivery != .delivered) {
            continue;
        }
        if (index == null or edition.id < group_value.editions[index.?].?.id) {
            index = at;
        }
    }
    const at = index orelse return error.ReviewCapacity;
    const edition = group_value.editions[at].?;
    const archive = try self.gpa.create(Group);
    defer self.gpa.destroy(archive);
    archive.* = .{ .key = group_value.key, .context = group_value.context, .count = 1 };
    archive.editions[0] = edition;
    var input = self.storageInput(io);
    input.archive_id = edition.id;
    const manifest_bytes = try storage.manifestBytes(self.storageInput(io), group_value.key);
    input.byte_limit = storage.max_file_bytes -| (group_value.archivedBytes() - group_value.records[edition.id - 1].bytes + manifest_bytes);
    const bytes = try storage.save(input, archive);
    group_value.records[edition.id - 1].bytes = bytes;
    std.mem.copyForwards(?*Edition, group_value.editions[at .. group_value.count - 1], group_value.editions[at + 1 .. group_value.count]);
    group_value.count -= 1;
    group_value.editions[group_value.count] = null;
    self.gpa.destroy(edition);
}

fn loadArchived(self: *Service, io: std.Io, query: ArchivedQuery) !*Edition {
    const archive = try self.gpa.create(Group);
    defer self.gpa.destroy(archive);
    archive.* = .{ .key = query.group.key, .context = query.group.context };
    defer archive.deinit(self.gpa);
    var input = self.storageInput(io);
    input.archive_id = query.id;
    try storage.load(input, archive);
    if (archive.count != 1 or archive.editions[0].?.id != query.id or !std.mem.eql(u8, &archive.editions[0].?.identity, &query.group.records[query.id - 1].identity)) {
        return error.InvalidReviewStorage;
    }
    const edition = archive.editions[0].?;
    archive.count = 0;
    return edition;
}

fn activate(self: *Service, io: std.Io, input: Activation) !void {
    const group_value = input.group;
    if (group_value.count == Group.capacity) {
        try self.evict(io, group_value);
    }
    group_value.editions[group_value.count] = input.edition;
    group_value.count += 1;
    _ = storage.save(self.storageInput(io), group_value) catch |err| {
        group_value.count -= 1;
        group_value.editions[group_value.count] = null;
        return err;
    };
}

fn encodeResult(self: *Service, input: QueryInput) !*Result {
    const group_value = input.group;
    const query = input.query;
    var value = input.edition.view(query);
    value.session = group_value.context.sessionSlice();
    value.latest_edition_id = group_value.total;
    value.previous_edition_id = input.edition.id - 1;
    value.next_edition_id = if (input.edition.id == group_value.total) 0 else input.edition.id + 1;
    value.status = if (self.dropped.load(.monotonic) != 0) "Some edits could not be retained; the captured history may be incomplete." else switch (value.delivery) {
        .idle => "Comments are retained by the runtime. Send the review when ready.",
        .pending => "Awaiting delivery to the agent.",
        .delivered => "Review delivered to the agent.",
    };
    const result_value = try Result.init(self.gpa);
    errdefer result_value.deinit();
    result_value.len = (try core.encodeChangeReviewSnapshot(result_value.bytes, value)).len;
    return result_value;
}

fn empty(self: *Service, query: core.QueryChangeReview) !*Result {
    const result_value = try Result.init(self.gpa);
    errdefer result_value.deinit();
    result_value.len = (try core.encodeChangeReviewSnapshot(result_value.bytes, .{ .request_id = query.request_id, .pane_id = query.pane_id, .pane_generation = query.pane_generation, .session = query.session, .status = "No captured file edits in this agent session." })).len;
    return result_value;
}

fn storageInput(self: *Service, io: std.Io) StorageInput {
    return .{ .io = io, .gpa = self.gpa, .directory = self.directory, .global_bytes = &self.disk_bytes };
}

test "review service persists immutable editions comments and idempotent feedback across runtime restart" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try temp.dir.realPath(io, &root_buffer)];
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/reviews", .{root});
    var service = try Service.init(gpa, path);
    defer service.deinit();
    const context = try Context.init(.{ .id = @enumFromInt(2), .generation = 3 }, .codex, "official-thread");
    const patch = "Updated file.zig\n@@ -1,2 +1,2 @@\n-old\n+new\n context\n";
    const record: ProviderPatch = .{ .context = context, .turn = "turn-1", .item = "edit-1", .patch = patch };
    _ = try service.recordProvider(io, record);
    _ = try service.recordProvider(io, record);
    const query: core.QueryChangeReview = .{ .request_id = @enumFromInt(1), .pane_id = context.pane.id, .pane_generation = context.pane.generation };
    const first = try service.execute(io, .{ .context = context, .operation = .{ .query = query } });
    defer first.deinit();
    const original = try first.snapshot();
    try std.testing.expectEqual(@as(u64, 1), original.edition_id);
    var command: core.ChangeReviewCommand = .{ .request_id = query.request_id, .pane_id = query.pane_id, .pane_generation = query.pane_generation, .edition_id = 1, .expected_revision = 1, .action = .save_comment, .path = "file.zig", .first_line = 1, .last_line = 2, .body = "Retain café and 界." };
    const saved = try service.execute(io, .{ .context = context, .operation = .{ .command = command } });
    defer saved.deinit();
    try std.testing.expectError(error.StaleReview, service.execute(io, .{ .context = context, .operation = .{ .command = command } }));
    service.deinit();
    service = try Service.init(gpa, path);
    try std.testing.expectEqual(@as(u64, 1), try service.latestEdition(io, context));
    const restored = try service.execute(io, .{ .context = context, .operation = .{ .query = query } });
    defer restored.deinit();
    const restored_view = try restored.snapshot();
    try std.testing.expectEqualStrings(command.body, restored_view.comments()[0].body);
    try std.testing.expectEqualStrings(patch, restored_view.patch);
    command.action = .submit;
    command.expected_revision = restored_view.revision;
    const submitted = try service.execute(io, .{ .context = context, .operation = .{ .command = command } });
    defer submitted.deinit();
    const pending = try submitted.snapshot();
    try std.testing.expectEqual(core.change_review.Delivery.pending, pending.delivery);
    const duplicate = try service.execute(io, .{ .context = context, .operation = .{ .command = command } });
    defer duplicate.deinit();
    try std.testing.expectEqual(pending.revision, (try duplicate.snapshot()).revision);
    command.action = .ack_feedback;
    command.feedback_id = pending.feedback_id;
    const ack = try service.execute(io, .{ .context = context, .operation = .{ .command = command } });
    defer ack.deinit();
    try std.testing.expectEqual(core.change_review.Delivery.delivered, (try ack.snapshot()).delivery);
    try std.testing.expectEqual(@as(usize, 0), (try ack.snapshot()).feedback.len);
}

test "review samples produce a git diff from paired evidence without rereading the user path" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try temp.dir.realPath(io, &root_buffer)];
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/reviews", .{root});
    const service = try Service.init(gpa, path);
    defer service.deinit();
    const context = try Context.init(.{ .id = @enumFromInt(2), .generation = 3 }, .claude, "official-thread");
    var sample_value: core.ReportChangeReviewSample = .{ .request_id = @enumFromInt(1), .pane_id = context.pane.id, .pane_generation = context.pane.generation, .provider = .claude, .session = context.sessionSlice(), .tool_call_id = "edit-1", .phase = .before, .path = "/path/that/does/not/exist.zig", .exists = true, .content = "old\ncontext\n" };
    const before = try service.execute(io, .{ .context = context, .operation = .{ .sample = sample_value } });
    before.deinit();
    sample_value.phase = .after;
    sample_value.content = "new\ncontext\n";
    const after = try service.execute(io, .{ .context = context, .operation = .{ .sample = sample_value } });
    after.deinit();
    const query: core.QueryChangeReview = .{ .request_id = sample_value.request_id, .pane_id = sample_value.pane_id, .pane_generation = sample_value.pane_generation };
    const result = try service.execute(io, .{ .context = context, .operation = .{ .query = query } });
    defer result.deinit();
    const view = try result.snapshot();
    try std.testing.expectEqual(core.change_review.Source.observed_snapshot, view.source);
    try std.testing.expect(std.mem.indexOf(u8, view.patch, "-old\n+new\n") != null);
    sample_value.tool_call_id = "unpaired";
    try std.testing.expectError(error.MissingReviewBaseline, service.execute(io, .{ .context = context, .operation = .{ .sample = sample_value } }));
}

test "review archive retains old editions beyond the hot cache and reactivates comments after restart" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try temp.dir.realPath(io, &root_buffer)];
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/reviews", .{root});
    var service = try Service.init(gpa, path);
    defer service.deinit();
    const context = try Context.init(.{ .id = @enumFromInt(2), .generation = 3 }, .codex, "archived-thread");
    const patch = "Updated file.zig\n@@ -1 +1 @@\n-old\n+new\n";
    for (0..Group.capacity + 4) |index| {
        var id_buffer: [32]u8 = undefined;
        const item = try std.fmt.bufPrint(&id_buffer, "edit-{d}", .{index});
        _ = try service.recordProvider(io, .{ .context = context, .turn = "turn", .item = item, .patch = patch });
    }
    const query: core.QueryChangeReview = .{ .request_id = @enumFromInt(1), .pane_id = context.pane.id, .pane_generation = context.pane.generation, .edition_id = 1 };
    const archived = try service.execute(io, .{ .context = context, .operation = .{ .query = query } });
    defer archived.deinit();
    const first = try archived.snapshot();
    try std.testing.expectEqual(@as(u64, Group.capacity + 4), first.latest_edition_id);
    try std.testing.expectEqual(@as(u64, 2), first.next_edition_id);
    try std.testing.expectEqualStrings(patch, first.patch);
    const command: core.ChangeReviewCommand = .{ .request_id = query.request_id, .pane_id = query.pane_id, .pane_generation = query.pane_generation, .edition_id = 1, .expected_revision = 1, .action = .save_comment, .path = "file.zig", .first_line = 1, .last_line = 1, .body = "A comment on the archived version." };
    const saved = try service.execute(io, .{ .context = context, .operation = .{ .command = command } });
    saved.deinit();
    service.deinit();
    service = try Service.init(gpa, path);
    const restored = try service.execute(io, .{ .context = context, .operation = .{ .query = query } });
    defer restored.deinit();
    try std.testing.expectEqualStrings(command.body, (try restored.snapshot()).comments()[0].body);
    try std.testing.expectEqual(@as(u64, Group.capacity + 4), (try restored.snapshot()).latest_edition_id);
    try std.testing.expectEqual(@as(u64, 1), try service.recordProvider(io, .{ .context = context, .turn = "turn", .item = "edit-0", .patch = patch }));
}

test "review generation changes discard unmatched evidence while retained editions remain session-owned" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try temp.dir.realPath(io, &root_buffer)];
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/reviews", .{root});
    const service = try Service.init(gpa, path);
    defer service.deinit();
    var context = try Context.init(.{ .id = @enumFromInt(2), .generation = 3 }, .claude, "thread");
    var sample_value: core.ReportChangeReviewSample = .{ .request_id = @enumFromInt(1), .pane_id = context.pane.id, .pane_generation = context.pane.generation, .provider = .claude, .session = "thread", .tool_call_id = "edit", .phase = .before, .path = "/file.zig", .exists = true, .content = "old\n" };
    const before = try service.execute(io, .{ .context = context, .operation = .{ .sample = sample_value } });
    before.deinit();
    context.pane.generation += 1;
    sample_value.pane_generation += 1;
    sample_value.phase = .after;
    sample_value.content = "new\n";
    try std.testing.expectEqual(@as(u64, 0), try service.latestEdition(io, context));
    try std.testing.expectError(error.MissingReviewBaseline, service.execute(io, .{ .context = context, .operation = .{ .sample = sample_value } }));
    sample_value.phase = .before;
    sample_value.content = "old\n";
    const current_before = try service.execute(io, .{ .context = context, .operation = .{ .sample = sample_value } });
    current_before.deinit();
    var stale_context = context;
    stale_context.pane.generation -= 1;
    try std.testing.expectEqual(@as(u64, 0), try service.latestEdition(io, stale_context));
    sample_value.phase = .after;
    sample_value.content = "new\n";
    const current_after = try service.execute(io, .{ .context = context, .operation = .{ .sample = sample_value } });
    current_after.deinit();
    try std.testing.expectEqual(@as(u64, 1), try service.latestEdition(io, context));
}
