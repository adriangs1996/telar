const cellgrid = @import("cellgrid");
const agent_options_module = @import("agent_options.zig");
const std = @import("std");
const builtin = @import("builtin");
const DamageRow = @import("DamageRow.zig");
const Applied = @import("Applied.zig");
const frames = @import("frame.zig");
const damage = @import("damage.zig");
const pane_support = @import("pane_support.zig");
const Pane = @This();
const core = @import("telar-core");
pub const ImageRemoval = @import("ComposerImageRemoval.zig");
const ChangeReviewAvailability = @import("ChangeReviewAvailability.zig");

const Composer = @import("Composer.zig");

gpa: std.mem.Allocator,
id: core.PaneId,
location: core.TabLocation,
buffer: cellgrid.Buffer,
text_metadata: *core.TextMetadata,
damage_rows: []DamageRow,
attached: bool,
attachment_generation: u64 = 0,
cursor: core.Cursor = .{},
mouse: core.Mouse = .{},
input_modes: core.InputModes = .{},
pointer_shape: core.PointerShape = .default,
scroll: core.Scroll,
applied_frame_id: u64 = 0,
pending_frame_id: u64 = 0,
graphics_placeholder: bool = false,
cwd: []u8 = &.{},
foreground_name: [core.max_foreground_name_bytes]u8 = @splat(0),
foreground_name_len: u8 = 0,
progress_state: core.PaneProgressState = .remove,
progress_percent: ?u8 = null,
title: []u8 = &.{},
/// What the user is writing for the agent in this pane, allocated on first
/// use and owned like the title.
composer: ?*Composer = null,
/// Advances on every composer edit, including selection moves.
composer_revision: u64 = 0,
/// Advances only when the composer's text or images change.
composer_content_revision: u64 = 0,
kind: core.PaneKind = .terminal,
pane_generation: u64 = 0,
change_review: ChangeReviewAvailability = .{},
agent_thread: ?*core.AgentThreadSnapshot = null,
agent_history: ?*AgentHistoryWindow = null,
history_intent: ?core.agent_history.Direction = null,
history_generation: u64 = 0,
transcript_scroll: f64 = 0,
transcript_anchor_revision: u64 = 0,
agent_options: ?*core.AgentOptions = null,
options_revision: u64 = 0,
catalog_revision: u64 = 0,
resume_history_requested: bool = false,

pub const Initial = @import("Initial.zig");
const AgentHistoryWindow = @import("AgentHistoryWindow.zig");

/// Reserves cells and row damage for one validated pane. Example: var pane = try Pane.init(gpa, initial);
pub fn init(gpa: std.mem.Allocator, initial: Initial) !Pane {
    if (initial.spec.pane_id == .invalid) {
        return error.InvalidPaneId;
    }

    try initial.spec.size.validate();
    var buffer = try cellgrid.Buffer.init(gpa, initial.spec.size.cols, initial.spec.size.rows);
    errdefer buffer.deinit();

    const rows = try gpa.alloc(DamageRow, initial.spec.size.rows);
    errdefer gpa.free(rows);
    @memset(rows, .{});
    const text_metadata = try gpa.create(core.TextMetadata);
    errdefer gpa.destroy(text_metadata);
    text_metadata.* = try .init(gpa, initial.spec.size.rows);
    return .{
        .text_metadata = text_metadata,
        .gpa = gpa,
        .id = initial.spec.pane_id,
        .location = initial.spec.location,
        .buffer = buffer,
        .damage_rows = rows,
        .attached = initial.attached,
        .scroll = .{ .total_rows = initial.spec.size.rows, .offset = 0 },
    };
}

pub fn deinit(self: *Pane) void {
    self.gpa.free(self.cwd);
    self.gpa.free(self.title);
    if (self.composer) |composer| {
        self.gpa.destroy(composer);
    }
    if (self.agent_thread) |thread| {
        self.gpa.destroy(thread);
    }
    self.clearHistory();
    if (self.agent_options) |options| {
        self.gpa.destroy(options);
    }
    self.gpa.free(self.damage_rows);
    self.text_metadata.deinit(self.gpa);
    self.gpa.destroy(self.text_metadata);
    self.buffer.deinit();
}

/// Applies a decoded frame after identity and base admission. Only a
/// snapshot may resize storage. Example: const work = try pane.applyFrame(frame);
pub fn applyFrame(self: *Pane, frame: core.FrameView) !Applied {
    core.profiling.add(.pane_apply_frame, 1);
    if (frame.pane_id != self.id) {
        return error.PaneMismatch;
    }

    if (frame.base_frame_id != 0 and frame.base_frame_id != self.applied_frame_id) {
        return error.FrameBaseMismatch;
    }

    const metadata = if (frame.text_metadata) |value|
        try core.TextMetadataView.decode(value.encoded, .{ frame.cols, frame.rows })
    else if (frame.base_frame_id == 0)
        return error.MissingSnapshotMetadata
    else
        null;
    const resized = self.buffer.w != frame.cols or self.buffer.h != frame.rows;
    if (resized and frame.base_frame_id != 0) {
        if (!builtin.is_test) {
            std.log.err(
                "pane {any}: patch frame={d} base={d}, applied={d}, incoming={d}x{d}, buffer={d}x{d}",
                .{
                    self.id,
                    frame.frame_id,
                    frame.base_frame_id,
                    self.applied_frame_id,
                    frame.cols,
                    frame.rows,
                    self.buffer.w,
                    self.buffer.h,
                },
            );
        }

        return error.PatchSizeMismatch;
    }

    try self.text_metadata.reserve(self.gpa, frame.rows);
    const replacement_damage = if (resized) try self.gpa.alloc(DamageRow, frame.rows) else null;
    errdefer if (replacement_damage) |rows| self.gpa.free(rows);

    const applied = try frames.applyBuffer(&self.buffer, &self.cursor, frame);
    if (metadata) |value| {
        self.text_metadata.replace(value);
    }

    self.mouse = frame.mouse;
    self.input_modes = frame.input_modes;
    self.pointer_shape = frame.pointer_shape;
    self.scroll = frame.scroll;
    if (replacement_damage) |rows| {
        @memset(rows, .{});
        self.gpa.free(self.damage_rows);
        self.damage_rows = rows;
    } else {
        var spans = frame.spans();
        while (try spans.next()) |span| {
            self.markSpan(span.start, span.cell_count);
        }
    }

    self.applied_frame_id = frame.frame_id;
    self.pending_frame_id = frame.frame_id;
    core.profiling.add(.pane_copy_cells, applied.cells);
    core.profiling.add(.pane_copy_bytes, applied.cells * @sizeOf(cellgrid.Cell));
    return applied;
}

/// Retires only the exact pending presentation. Example: pane.commitPresentation(frame_id);
pub fn commitPresentation(self: *Pane, frame_id: u64) void {
    if (self.pending_frame_id != frame_id) {
        return;
    }

    for (self.damage_rows) |*row| {
        row.clear();
    }

    self.pending_frame_id = 0;
}

/// Marks a validated range of owned cells. Example: pane.markSpan(1, 2);
pub fn markSpan(self: *Pane, start: u32, count: u32) void {
    damage.markRows(self.damage_rows, self.buffer.w, .{ .start = start, .count = count });
}

/// Owns the full path and reports changes to its bounded display name.
/// Example: const changed = try pane.setCwd("/work/telar");
pub fn setCwd(self: *Pane, path: []const u8) !bool {
    std.debug.assert(path.len != 0 and path.len <= core.max_cwd_bytes);
    if (std.mem.eql(u8, self.cwd, path)) {
        return false;
    }

    const display_changed = !std.mem.eql(u8, self.cwdName(), pane_support.displayCwdName(path));
    const replacement = try self.gpa.dupe(u8, path);
    self.gpa.free(self.cwd);
    self.cwd = replacement;
    return display_changed;
}

pub fn cwdName(self: *const Pane) []const u8 {
    return pane_support.displayCwdName(self.cwd);
}

pub fn cwdSlice(self: *const Pane) []const u8 {
    return self.cwd;
}

/// Replaces a validated foreground label without allocation. Example: _ = pane.setForegroundName("zsh");
pub fn setForegroundName(self: *Pane, name: []const u8) bool {
    std.debug.assert(name.len != 0 and name.len <= self.foreground_name.len);
    if (std.mem.eql(u8, self.foregroundName(), name)) {
        return false;
    }

    @memcpy(self.foreground_name[0..name.len], name);
    self.foreground_name_len = @intCast(name.len);
    return true;
}

pub fn foregroundName(self: *const Pane) []const u8 {
    return self.foreground_name[0..self.foreground_name_len];
}

/// Replaces a semantic progress report without allocation. Example: _ = pane.setProgress(progress);
pub fn setProgress(self: *Pane, progress: core.PaneProgress) bool {
    if (self.progress_state == progress.state and self.progress_percent == progress.percent) {
        return false;
    }

    self.progress_state = progress.state;
    self.progress_percent = progress.percent;
    return true;
}

/// Owns a validated window title independently of its request buffer. Example: _ = try pane.setTitle("vim");
pub fn setTitle(self: *Pane, title: []const u8) !bool {
    std.debug.assert(title.len <= core.max_pane_title_bytes);
    if (std.mem.eql(u8, self.title, title)) {
        return false;
    }

    const replacement = if (title.len != 0) try self.gpa.dupe(u8, title) else &[_]u8{};
    self.gpa.free(self.title);
    self.title = @constCast(replacement);
    return true;
}

pub fn titleSlice(self: *const Pane) []const u8 {
    return self.title;
}

pub const max_composer_bytes = Composer.max_bytes;

/// Replaces the composer draft the thread surface shows.
///
/// ```zig
/// try pane.setComposer("fix the failing test");
/// ```
pub fn setComposer(self: *Pane, text: []const u8) !void {
    if (text.len > max_composer_bytes) {
        return error.ComposerTooLong;
    }

    if (!std.unicode.utf8ValidateSlice(text)) {
        return error.InvalidUtf8;
    }

    if (std.mem.indexOfScalar(u8, text, 0) != null) {
        return error.InvalidComposerText;
    }

    const content_changed = !std.mem.eql(u8, self.composerSlice(), text);
    if (self.composer == null and text.len == 0) {
        return;
    }

    const field = &(try self.ensureComposer()).field;
    if (field.replace(.{ 0, @intCast(field.len) }, text)) {
        self.composer_revision +%= 1;
        if (content_changed) {
            self.composer_content_revision +%= 1;
        }
    }
}

pub fn composerSlice(self: *const Pane) []const u8 {
    const composer = self.composer orelse return "";
    return composer.field.text();
}

/// The composer, allocated on first use.
/// Example: `const composer = try pane.ensureComposer();`
pub fn ensureComposer(self: *Pane) !*Composer {
    if (self.composer) |composer| {
        return composer;
    }

    const composer = try self.gpa.create(Composer);
    composer.* = .{};
    self.composer = composer;
    return composer;
}

/// Installs a client attachment, preserving notices received before its first frame.
/// Example: `pane.attach(generation);`
pub fn attach(self: *Pane, generation: u64) void {
    if (self.attached and self.attachment_generation == 0) {
        self.change_review.attachment_generation = generation;
    } else if (!self.attached or self.attachment_generation != generation) {
        self.change_review = .{};
    }

    self.attached = true;
    self.attachment_generation = generation;
}

/// Retains availability for ordinary terminals and managed agent panes alike.
/// Example: `_ = pane.applyChangeReview(notification);`
pub fn applyChangeReview(self: *Pane, notification: core.ChangeReviewChanged) bool {
    if (!self.attached or self.pane_generation == 0 or self.id != notification.pane_id or self.pane_generation != notification.pane_generation) {
        return false;
    }

    return self.change_review.apply(notification, self.attachment_generation);
}

/// Reports recorded editions belonging to this exact attached pane lifetime.
/// Example: `if (pane.hasChangeReview()) drawReviewAction();`
pub fn hasChangeReview(self: *const Pane) bool {
    return self.attached and self.change_review.pane_generation == self.pane_generation and self.change_review.attachment_generation == self.attachment_generation and self.change_review.latest_edition_id != 0;
}

/// Installs the runtime identity and retires cached state for another lifetime.
/// Example: `_ = pane.identify(.agent, generation);`
pub fn identify(self: *Pane, kind: core.PaneKind, generation: u64) bool {
    if (self.kind == kind and self.pane_generation == generation) {
        return false;
    }

    if (self.agent_thread) |thread| {
        self.gpa.destroy(thread);
        self.agent_thread = null;
    }
    self.clearHistory();

    self.kind = kind;
    self.pane_generation = generation;
    self.change_review = .{};
    self.transcript_scroll = 0;
    if (self.agent_options) |options| {
        self.gpa.destroy(options);
        self.agent_options = null;
    }
    self.catalog_revision = 0;
    self.resume_history_requested = false;
    self.options_revision +%= 1;
    return true;
}

/// Copies a validated snapshot only for this attached runtime lifetime.
/// Example: `_ = try pane.applyAgentThread(snapshot);`
pub fn applyAgentThread(self: *Pane, snapshot: core.AgentThreadSnapshotView) !bool {
    if (!self.attached or self.kind != .agent or self.id != snapshot.pane_id or self.pane_generation != snapshot.pane_generation) {
        return false;
    }

    if (self.agent_thread) |previous| {
        if (snapshot.revision <= previous.revision) {
            return false;
        }

        const old_id = previous.thread_id;
        const old_len = previous.thread_id_len;
        try snapshot.copyTo(previous);
        if (!std.mem.eql(u8, old_id[0..old_len], previous.threadId())) {
            self.clearHistory();
            self.transcript_scroll = 0;
            self.resume_history_requested = false;
        }
    } else {
        const replacement = try self.gpa.create(core.AgentThreadSnapshot);
        errdefer self.gpa.destroy(replacement);
        try snapshot.copyTo(replacement);
        self.agent_thread = replacement;
    }

    const retained = self.agent_thread.?;
    self.change_review.retainSession(retained.threadId());
    self.catalog_revision = catalogRevision(retained);
    if (retained.resumed and !self.resume_history_requested) {
        self.clearHistory();
        self.history_intent = .older;
        self.resume_history_requested = true;
    }

    _ = self.followAgentThread();
    if (self.agent_options == null or !retained.accepts(self.agent_options.?.*)) {
        if (retained.accepts(retained.options)) {
            if (self.agent_options == null) {
                self.agent_options = try self.gpa.create(core.AgentOptions);
            }
            self.agent_options.?.* = retained.options;
            self.options_revision +%= 1;
        }
    }

    return true;
}

/// Borrows a draft's settings through an owned value. Empty values mean startup is incomplete. Example: `const options = pane.agentOptions();`
pub fn agentOptions(self: *const Pane) core.AgentOptions {
    return if (self.agent_options) |options| options.* else .{};
}

/// Applies one catalog-backed draft choice without changing another client's settings. Example: `_ = pane.changeAgentOption(.{ .access = .read_only });`
pub fn changeAgentOption(self: *Pane, change: agent_options_module.Change) bool {
    const snapshot = self.agent_thread orelse return false;
    var options = self.agentOptions();
    switch (change) {
        .model => |id| {
            if (std.mem.eql(u8, options.modelSlice(), id)) {
                return false;
            }

            const model = snapshot.findModel(id) orelse return false;
            options.setModel(model.idSlice()) catch return false;
            options.effort = model.default_effort;
        },
        .effort => |effort| options.effort = effort,
        .access => |access| options.access = access,
    }
    if (!snapshot.accepts(options) or options.eql(self.agentOptions())) {
        return false;
    }

    const draft = self.agent_options orelse return false;
    draft.* = options;
    self.options_revision +%= 1;
    return true;
}

fn catalogRevision(snapshot: *const core.AgentThreadSnapshot) u64 {
    var hash = std.hash.Wyhash.init(0);
    hash.update(&.{snapshot.model_count});
    for (snapshot.models()) |model| {
        hash.update(&.{ model.id_len, model.label_len, model.effort_count });
        hash.update(model.idSlice());
        hash.update(model.labelSlice());
        for (model.efforts()) |effort| {
            hash.update(&.{effort.id_len});
            hash.update(effort.idSlice());
        }
        hash.update(&.{model.default_effort.id_len});
        hash.update(model.default_effort.idSlice());
    }
    return hash.final();
}

/// Borrows image references without allocating storage for empty terminal panes.
/// Example: `const images = pane.composerImages();`
pub fn composerImages(self: *const Pane) *const core.AgentImages {
    const composer = self.composer orelse return &empty_composer_images;
    return &composer.images;
}

const empty_composer_images: core.AgentImages = .{};

/// Changes bounded draft attachments and invalidates pending paste/send revisions.
/// Example: `try pane.attachComposerImage("/private/tmp/image.png");`
pub fn attachComposerImage(self: *Pane, path: []const u8) !void {
    try core.AgentImages.validatePath(path);
    const composer = try self.ensureComposer();
    try composer.images.append(path);
    self.composer_revision +%= 1;
    self.composer_content_revision +%= 1;
}

/// Rejects stale removal controls after another edit. Example: `_ = pane.removeComposerImage(.{ .index = 0, .revision = revision });`
pub fn removeComposerImage(self: *Pane, removal: ImageRemoval) bool {
    const composer = self.composer orelse return false;
    if (removal.revision != self.composer_revision or !composer.images.remove(removal.index)) {
        return false;
    }

    self.composer_revision +%= 1;
    self.composer_content_revision +%= 1;
    return true;
}

/// Clears exactly the draft accepted by the runtime. Example: `_ = pane.acceptComposer(revision);`
pub fn acceptComposer(self: *Pane, revision: u64) bool {
    if (self.composer_content_revision != revision) {
        return false;
    }

    self.setComposer("") catch unreachable;
    if (self.composerImages().count != 0) {
        self.composer.?.images = .{};
        self.composer_revision +%= 1;
        self.composer_content_revision +%= 1;
    }

    self.clearHistory();
    self.transcript_scroll = 0;
    return true;
}

/// Retires the disposable reading window; pending generations become stale.
/// Example: `pane.clearHistory();`
pub fn clearHistory(self: *Pane) void {
    if (self.agent_history) |window| {
        self.gpa.destroy(window);
        self.agent_history = null;
    }
    self.history_intent = null;
    self.history_generation +%= 1;
}

/// Refreshes the live tail only while the reader remains at its end.
/// Example: `_ = pane.followAgentThread();`
pub fn followAgentThread(self: *Pane) bool {
    if (self.transcript_scroll != 0) {
        return false;
    }

    const window = self.agent_history orelse return false;
    const live = self.agent_thread orelse return false;
    return window.followLive(live);
}

/// Resolves delivered history controls without falling through to newer bytes.
/// Example: `const snapshot = pane.threadItemSource(identity) orelse return;`
pub fn threadItemSource(self: *const Pane, identity: u64) ?*const core.AgentThreadSnapshot {
    if (self.agent_history) |window| {
        return window.findItem(identity);
    }
    const snapshot = self.agent_thread orelse return null;
    return if (snapshot.findItem(identity) != null) snapshot else null;
}

/// Retains bounded client navigation from the end of the transcript.
/// Example: `_ = pane.scrollConversation(3);`
pub fn scrollConversation(self: *Pane, delta: f64) bool {
    if (!std.math.isFinite(delta)) {
        return false;
    }

    const next = std.math.clamp(self.transcript_scroll + delta, 0, @as(f64, std.math.maxInt(u32)));
    if (next == self.transcript_scroll) {
        return false;
    }

    self.transcript_scroll = next;
    return true;
}

/// Applies bounded editor input without allocating. Example: `_ = pane.editComposer(.backspace);`
pub fn editComposer(self: *Pane, command: anytype) bool {
    const field = &(self.ensureComposer() catch return false).field;
    const previous = .{ field.len, field.head, field.anchor };
    const content_changed = switch (command) {
        .insert => |text| replacementChangesText(field, .{ @intCast(@min(field.head, field.anchor)), @intCast(@max(field.head, field.anchor)) }, text),
        .replace_range => |replacement| replacementChangesText(field, replacement.range, replacement.text),
        .backspace, .delete => true,
        else => false,
    };
    const changed = switch (command) {
        .insert => |text| if (std.mem.indexOfScalar(u8, text, 0) != null) false else field.replace(.{ @intCast(@min(field.head, field.anchor)), @intCast(@max(field.head, field.anchor)) }, text),
        .replace_range => |replacement| if (std.mem.indexOfScalar(u8, replacement.text, 0) != null) false else field.replace(replacement.range, replacement.text),
        .select_range => |range| field.selectRange(range),
        .select_all => action: {
            field.selectAll();
            break :action !std.meta.eql(previous, .{ field.len, field.head, field.anchor });
        },
        .backspace => action: {
            field.backspace();
            break :action field.len != previous[0];
        },
        .delete => action: {
            field.delete();
            break :action field.len != previous[0];
        },
        .move_left => |extend| action: {
            field.moveLeft(extend);
            break :action !std.meta.eql(previous, .{ field.len, field.head, field.anchor });
        },
        .move_right => |extend| action: {
            field.moveRight(extend);
            break :action !std.meta.eql(previous, .{ field.len, field.head, field.anchor });
        },
        .home => |extend| action: {
            field.home(extend);
            break :action !std.meta.eql(previous, .{ field.len, field.head, field.anchor });
        },
        .end => |extend| action: {
            field.end(extend);
            break :action !std.meta.eql(previous, .{ field.len, field.head, field.anchor });
        },
        else => false,
    };
    if (changed) {
        self.composer_revision +%= 1;
        if (content_changed) {
            self.composer_content_revision +%= 1;
        }
    }

    return changed;
}

fn replacementChangesText(field: *const Composer.Field, range: [2]u32, text: []const u8) bool {
    if (range[0] > range[1] or range[1] > field.len) {
        return false;
    }

    return !std.mem.eql(u8, field.text()[range[0]..range[1]], text);
}
