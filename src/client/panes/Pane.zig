const InitialType = @import("Initial.zig");
const std = @import("std");
const PaneIdType = @import("telar-core").PaneId;
const TabLocationType = @import("telar-core").TabLocation;
const BufferType = @import("telar-core").Buffer;
const DamageRowType = @import("DamageRow.zig");
const CursorType = @import("telar-core").Cursor;
const MouseType = @import("telar-core").Mouse;
const InputModesType = @import("telar-core").InputModes;
const PointerShapeType = @import("telar-core").PointerShape;
const ScrollType = @import("telar-core").Scroll;
const max_foreground_name_bytes_module = @import("telar-core").max_foreground_name_bytes;
const PaneProgressStateType = @import("telar-core").PaneProgressState;
const FrameViewType = @import("telar-core").FrameView;
const AppliedType = @import("Applied.zig");
const frames = @import("frame.zig");
const damage = @import("damage.zig");
const max_cwd_bytes_module = @import("telar-core").max_cwd_bytes;
const pane_support = @import("pane_support.zig");
const PaneProgressType = @import("telar-core").PaneProgress;
const max_pane_title_bytes_module = @import("telar-core").max_pane_title_bytes;
const Pane = @This();
const IconType = @import("../layout/icons.zig").Icon;
const core = @import("telar-core");
pub const ImageRemoval = @import("ComposerImageRemoval.zig");
const GenericField = @import("../input/GenericField.zig").Type;

pub const ComposerField = GenericField(4096);

gpa: std.mem.Allocator,
id: PaneIdType,
location: TabLocationType,
buffer: BufferType,
text_metadata: *@import("telar-core").TextMetadata,
damage_rows: []DamageRowType,
attached: bool,
attachment_generation: u64 = 0,
cursor: CursorType = .{},
mouse: MouseType = .{},
input_modes: InputModesType = .{},
pointer_shape: PointerShapeType = .default,
scroll: ScrollType,
applied_frame_id: u64 = 0,
pending_frame_id: u64 = 0,
graphics_placeholder: bool = false,
cwd: []u8 = &.{},
foreground_name: [max_foreground_name_bytes_module]u8 = @splat(0),
foreground_name_len: u8 = 0,
progress_state: PaneProgressStateType = .remove,
progress_percent: ?u8 = null,
title: []u8 = &.{},
/// What the user is writing for the agent in this pane, owned like the title.
composer_field: *ComposerField,
composer_revision: u64 = 0,
composer_images: ?*core.AgentImages = null,
composer_content_revision: u64 = 0,
kind: core.PaneKind = .terminal,
pane_generation: u64 = 0,
agent_thread: ?*core.AgentThreadSnapshot = null,
agent_history: ?*@import("AgentHistoryWindow.zig") = null,
history_intent: ?core.agent_history.Direction = null,
history_generation: u64 = 0,
transcript_scroll: u32 = 0,
transcript_anchor_revision: u64 = 0,
agent_options: ?*core.AgentOptions = null,
options_revision: u64 = 0,
catalog_revision: u64 = 0,
resume_history_requested: bool = false,

pub const Initial = @import("Initial.zig");

/// Reserves cells and row damage for one validated pane. Example: var pane = try Pane.init(gpa, initial);
pub fn init(gpa: std.mem.Allocator, initial: InitialType) !Pane {
    if (initial.spec.pane_id == .invalid) {
        return error.InvalidPaneId;
    }

    try initial.spec.size.validate();
    var buffer = try BufferType.init(gpa, initial.spec.size.cols, initial.spec.size.rows);
    errdefer buffer.deinit();

    const rows = try gpa.alloc(DamageRowType, initial.spec.size.rows);
    errdefer gpa.free(rows);
    @memset(rows, .{});
    const composer_field = try gpa.create(ComposerField);
    errdefer gpa.destroy(composer_field);
    composer_field.* = .{};
    const text_metadata = try gpa.create(@import("telar-core").TextMetadata);
    errdefer gpa.destroy(text_metadata);
    text_metadata.* = try .init(gpa, initial.spec.size.rows);
    return .{
        .text_metadata = text_metadata,
        .gpa = gpa,
        .id = initial.spec.pane_id,
        .location = initial.spec.location,
        .buffer = buffer,
        .damage_rows = rows,
        .composer_field = composer_field,
        .attached = initial.attached,
        .scroll = .{ .total_rows = initial.spec.size.rows, .offset = 0 },
    };
}

pub fn deinit(pane: *Pane) void {
    pane.gpa.free(pane.cwd);
    pane.gpa.free(pane.title);
    pane.gpa.destroy(pane.composer_field);
    if (pane.composer_images) |images| {
        pane.gpa.destroy(images);
    }
    if (pane.agent_thread) |thread| {
        pane.gpa.destroy(thread);
    }
    pane.clearHistory();
    if (pane.agent_options) |options| {
        pane.gpa.destroy(options);
    }
    pane.gpa.free(pane.damage_rows);
    pane.text_metadata.deinit(pane.gpa);
    pane.gpa.destroy(pane.text_metadata);
    pane.buffer.deinit();
}

/// Applies a decoded frame after identity and base admission. Only a
/// snapshot may resize storage. Example: const work = try pane.applyFrame(frame);
pub fn applyFrame(pane: *Pane, frame: FrameViewType) !AppliedType {
    if (frame.pane_id != pane.id) {
        return error.PaneMismatch;
    }

    if (frame.base_frame_id != 0 and frame.base_frame_id != pane.applied_frame_id) {
        return error.FrameBaseMismatch;
    }

    const metadata = if (frame.text_metadata) |value|
        try @import("telar-core").TextMetadataView.decode(value.encoded, .{ frame.cols, frame.rows })
    else if (frame.base_frame_id == 0)
        return error.MissingSnapshotMetadata
    else
        null;
    const resized = pane.buffer.w != frame.cols or pane.buffer.h != frame.rows;
    if (resized and frame.base_frame_id != 0) {
        return error.PatchSizeMismatch;
    }

    try pane.text_metadata.reserve(pane.gpa, frame.rows);
    const replacement_damage = if (resized) try pane.gpa.alloc(DamageRowType, frame.rows) else null;
    errdefer if (replacement_damage) |rows| pane.gpa.free(rows);

    const applied = try frames.applyBuffer(&pane.buffer, &pane.cursor, frame);
    if (metadata) |value| {
        pane.text_metadata.replace(value);
    }

    pane.mouse = frame.mouse;
    pane.input_modes = frame.input_modes;
    pane.pointer_shape = frame.pointer_shape;
    pane.scroll = frame.scroll;
    if (replacement_damage) |rows| {
        @memset(rows, .{});
        pane.gpa.free(pane.damage_rows);
        pane.damage_rows = rows;
    } else {
        var spans = frame.spans();
        while (try spans.next()) |span| {
            pane.markSpan(span.start, span.cell_count);
        }
    }

    pane.applied_frame_id = frame.frame_id;
    pane.pending_frame_id = frame.frame_id;
    return applied;
}

/// Retires only the exact pending presentation. Example: pane.commitPresentation(frame_id);
pub fn commitPresentation(pane: *Pane, frame_id: u64) void {
    if (pane.pending_frame_id != frame_id) {
        return;
    }

    for (pane.damage_rows) |*row| {
        row.clear();
    }

    pane.pending_frame_id = 0;
}

/// Marks a validated range of owned cells. Example: pane.markSpan(1, 2);
pub fn markSpan(pane: *Pane, start: u32, count: u32) void {
    damage.markRows(pane.damage_rows, pane.buffer.w, .{ .start = start, .count = count });
}

/// Owns the full path and reports changes to its bounded display name.
/// Example: const changed = try pane.setCwd("/work/telar");
pub fn setCwd(pane: *Pane, path: []const u8) !bool {
    std.debug.assert(path.len != 0 and path.len <= max_cwd_bytes_module);
    if (std.mem.eql(u8, pane.cwd, path)) {
        return false;
    }

    const display_changed = !std.mem.eql(u8, pane.cwdName(), pane_support.displayCwdName(path));
    const replacement = try pane.gpa.dupe(u8, path);
    pane.gpa.free(pane.cwd);
    pane.cwd = replacement;
    return display_changed;
}

pub fn cwdName(pane: *const Pane) []const u8 {
    return pane_support.displayCwdName(pane.cwd);
}

pub fn cwdSlice(pane: *const Pane) []const u8 {
    return pane.cwd;
}

/// Replaces a validated foreground label without allocation. Example: _ = pane.setForegroundName("zsh");
pub fn setForegroundName(pane: *Pane, name: []const u8) bool {
    std.debug.assert(name.len != 0 and name.len <= pane.foreground_name.len);
    if (std.mem.eql(u8, pane.foregroundName(), name)) {
        return false;
    }

    @memcpy(pane.foreground_name[0..name.len], name);
    pane.foreground_name_len = @intCast(name.len);
    return true;
}

pub fn foregroundName(pane: *const Pane) []const u8 {
    return pane.foreground_name[0..pane.foreground_name_len];
}

pub fn applicationLabel(pane: *const Pane) []const u8 {
    const name = pane.foregroundName();
    return if (name.len != 0) name else "shell";
}

pub fn applicationIcon(pane: *const Pane) IconType {
    return IconType.forApplication(pane.foregroundName());
}

/// Replaces a semantic progress report without allocation. Example: _ = pane.setProgress(progress);
pub fn setProgress(pane: *Pane, progress: PaneProgressType) bool {
    if (pane.progress_state == progress.state and pane.progress_percent == progress.percent) {
        return false;
    }

    pane.progress_state = progress.state;
    pane.progress_percent = progress.percent;
    return true;
}

/// Owns a validated window title independently of its request buffer. Example: _ = try pane.setTitle("vim");
pub fn setTitle(pane: *Pane, title: []const u8) !bool {
    std.debug.assert(title.len <= max_pane_title_bytes_module);
    if (std.mem.eql(u8, pane.title, title)) {
        return false;
    }

    const replacement = if (title.len != 0) try pane.gpa.dupe(u8, title) else &[_]u8{};
    pane.gpa.free(pane.title);
    pane.title = @constCast(replacement);
    return true;
}

pub fn titleSlice(pane: *const Pane) []const u8 {
    return pane.title;
}

pub const max_composer_bytes = 4096;

/// Replaces the composer draft the thread surface shows.
///
/// ```zig
/// try pane.setComposer("fix the failing test");
/// ```
pub fn setComposer(pane: *Pane, text: []const u8) !void {
    if (text.len > max_composer_bytes) {
        return error.ComposerTooLong;
    }

    if (!std.unicode.utf8ValidateSlice(text)) {
        return error.InvalidUtf8;
    }

    if (std.mem.indexOfScalar(u8, text, 0) != null) {
        return error.InvalidComposerText;
    }

    const content_changed = !std.mem.eql(u8, pane.composerSlice(), text);
    if (pane.composer_field.replace(.{ 0, @intCast(pane.composer_field.len) }, text)) {
        pane.composer_revision +%= 1;
        if (content_changed) {
            pane.composer_content_revision +%= 1;
        }
    }
}

pub fn composerSlice(pane: *const Pane) []const u8 {
    return pane.composer_field.text();
}

/// Installs the runtime identity and retires cached state for another lifetime.
/// Example: `_ = pane.identify(.agent, generation);`
pub fn identify(pane: *Pane, kind: core.PaneKind, generation: u64) bool {
    if (pane.kind == kind and pane.pane_generation == generation) {
        return false;
    }

    if (pane.agent_thread) |thread| {
        pane.gpa.destroy(thread);
        pane.agent_thread = null;
    }
    pane.clearHistory();

    pane.kind = kind;
    pane.pane_generation = generation;
    pane.transcript_scroll = 0;
    if (pane.agent_options) |options| {
        pane.gpa.destroy(options);
        pane.agent_options = null;
    }
    pane.catalog_revision = 0;
    pane.resume_history_requested = false;
    pane.options_revision +%= 1;
    return true;
}

/// Copies a validated snapshot only for this attached runtime lifetime.
/// Example: `_ = try pane.applyAgentThread(snapshot);`
pub fn applyAgentThread(pane: *Pane, snapshot: core.AgentThreadSnapshotView) !bool {
    if (!pane.attached or pane.kind != .agent or pane.id != snapshot.pane_id or pane.pane_generation != snapshot.pane_generation) {
        return false;
    }

    if (pane.agent_thread) |previous| {
        if (snapshot.revision <= previous.revision) {
            return false;
        }

        const old_id = previous.thread_id;
        const old_len = previous.thread_id_len;
        try snapshot.copyTo(previous);
        if (!std.mem.eql(u8, old_id[0..old_len], previous.threadId())) {
            pane.clearHistory();
            pane.transcript_scroll = 0;
            pane.resume_history_requested = false;
        }
    } else {
        const replacement = try pane.gpa.create(core.AgentThreadSnapshot);
        errdefer pane.gpa.destroy(replacement);
        try snapshot.copyTo(replacement);
        pane.agent_thread = replacement;
    }

    const retained = pane.agent_thread.?;
    pane.catalog_revision = catalogRevision(retained);
    if (retained.resumed and !pane.resume_history_requested) {
        pane.clearHistory();
        pane.history_intent = .older;
        pane.resume_history_requested = true;
    }
    if (pane.agent_options == null or !retained.accepts(pane.agent_options.?.*)) {
        if (retained.accepts(retained.options)) {
            if (pane.agent_options == null) {
                pane.agent_options = try pane.gpa.create(core.AgentOptions);
            }
            pane.agent_options.?.* = retained.options;
            pane.options_revision +%= 1;
        }
    }

    return true;
}

/// Borrows a draft's settings through an owned value. Empty values mean startup is incomplete. Example: `const options = pane.agentOptions();`
pub fn agentOptions(pane: *const Pane) core.AgentOptions {
    return if (pane.agent_options) |options| options.* else .{};
}

/// Applies one catalog-backed draft choice without changing another client's settings. Example: `_ = pane.changeAgentOption(.{ .access = .read_only });`
pub fn changeAgentOption(pane: *Pane, change: @import("agent_options.zig").Change) bool {
    const snapshot = pane.agent_thread orelse return false;
    var options = pane.agentOptions();
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
    if (!snapshot.accepts(options) or options.eql(pane.agentOptions())) {
        return false;
    }

    const draft = pane.agent_options orelse return false;
    draft.* = options;
    pane.options_revision +%= 1;
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
pub fn composerImages(pane: *const Pane) *const core.AgentImages {
    return pane.composer_images orelse &empty_composer_images;
}

const empty_composer_images: core.AgentImages = .{};

/// Changes bounded draft attachments and invalidates pending paste/send revisions.
/// Example: `try pane.attachComposerImage("/private/tmp/image.png");`
pub fn attachComposerImage(pane: *Pane, path: []const u8) !void {
    try core.AgentImages.validatePath(path);
    if (pane.composer_images == null) {
        const images = try pane.gpa.create(core.AgentImages);
        images.* = .{};
        pane.composer_images = images;
    }

    try pane.composer_images.?.append(path);
    pane.composer_revision +%= 1;
    pane.composer_content_revision +%= 1;
}

/// Rejects stale removal controls after another edit. Example: `_ = pane.removeComposerImage(.{ .index = 0, .revision = revision });`
pub fn removeComposerImage(pane: *Pane, removal: @import("ComposerImageRemoval.zig")) bool {
    const images = pane.composer_images orelse return false;
    if (removal.revision != pane.composer_revision or !images.remove(removal.index)) {
        return false;
    }

    pane.composer_revision +%= 1;
    pane.composer_content_revision +%= 1;
    return true;
}

/// Clears exactly the draft accepted by the runtime. Example: `_ = pane.acceptComposer(revision);`
pub fn acceptComposer(pane: *Pane, revision: u64) bool {
    if (pane.composer_content_revision != revision) {
        return false;
    }

    pane.setComposer("") catch unreachable;
    if (pane.composerImages().count != 0) {
        pane.composer_images.?.* = .{};
        pane.composer_revision +%= 1;
        pane.composer_content_revision +%= 1;
    }

    pane.clearHistory();
    pane.transcript_scroll = 0;
    return true;
}

/// Retires the disposable reading window; pending generations become stale.
/// Example: `pane.clearHistory();`
pub fn clearHistory(pane: *Pane) void {
    if (pane.agent_history) |window| {
        pane.gpa.destroy(window);
        pane.agent_history = null;
    }
    pane.history_intent = null;
    pane.history_generation +%= 1;
}

/// Resolves delivered history controls without falling through to newer bytes.
/// Example: `const snapshot = pane.threadItemSource(identity) orelse return;`
pub fn threadItemSource(pane: *const Pane, identity: u64) ?*const core.AgentThreadSnapshot {
    if (pane.agent_history) |window| {
        return window.findItem(identity);
    }
    const snapshot = pane.agent_thread orelse return null;
    return if (snapshot.findItem(identity) != null) snapshot else null;
}

/// Retains bounded client navigation from the end of the transcript.
/// Example: `_ = pane.scrollConversation(3);`
pub fn scrollConversation(pane: *Pane, delta: i32) bool {
    const next: u32 = @intCast(std.math.clamp(@as(i64, pane.transcript_scroll) + delta, 0, std.math.maxInt(u32)));
    if (next == pane.transcript_scroll) {
        return false;
    }

    pane.transcript_scroll = next;
    return true;
}

/// Applies bounded editor input without allocating. Example: `_ = pane.editComposer(.backspace);`
pub fn editComposer(pane: *Pane, command: anytype) bool {
    const field = pane.composer_field;
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
        pane.composer_revision +%= 1;
        if (content_changed) {
            pane.composer_content_revision +%= 1;
        }
    }

    return changed;
}

fn replacementChangesText(field: *const ComposerField, range: [2]u32, text: []const u8) bool {
    if (range[0] > range[1] or range[1] > field.len) {
        return false;
    }

    return !std.mem.eql(u8, field.text()[range[0]..range[1]], text);
}
