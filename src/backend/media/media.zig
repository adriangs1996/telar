//! Bounded Kitty graphics pipeline for one pane.
//!
//! The interactive terminal ignores Kitty APCs. This pipeline consumes a
//! copy of the same PTY output on a separate actor and owns the terminal whose
//! only durable product is graphics storage. Feeding all output, not only APC
//! payloads, keeps cursor-relative placements and scroll pins equivalent to
//! the interactive terminal without sharing mutable emulator state.
const kitty_protocol = @import("kitty_protocol");

const core = @import("telar-core");
const vt = @import("ghostty-vt");
const std = @import("std");
const ControlFields = kitty_protocol.ControlFields;
const Format = kitty_protocol.Format;
const SharedFrame = @import("SharedFrame.zig");
const SharedFrameKey = @import("SharedFrameKey.zig");
const FrameResource = @import("FrameResource.zig");
const builtin = @import("builtin");
const SharedFrameControl = @import("SharedFrameControl.zig");
const PlacementSource = @import("PlacementSource.zig");
const shared_transfer = @import("shared_transfer.zig");

pub const batch_bytes = 4 * 16 * 1024;
pub const batch_events = 64;

/// Raw pixels may cross the local child/runtime boundary through POSIX shared
/// memory. The emulator's own path-based media stays disabled so it can never
/// open an arbitrary file; complete file frames and file capability queries
/// are answered by the pane, which validates the file first.
pub const image_loading_limits: vt.kitty.graphics.LoadingImage.Limits = .{
    .file = false,
    .temporary_file = .disabled,
    .shared_memory = true,
};

/// Where a complete frame's pixels live before the runtime copies them.
pub const Medium = enum { shared, file };

const atomic_shared_prefix = "\x1b[?2026h\x1b[H\x1b_G";
const atomic_shared_suffix = "\x1b\\\x1b[?2026l";
/// DECSC and DECRC around an envelope, for a producer that keeps its own
/// cursor while it streams. A wrapped frame leaves the cursor where it found
/// it, so folding it away changes nothing but the saved cursor, which its
/// DECSC alone restores.
const cursor_save = "\x1b7";
const cursor_restore = "\x1b8";

pub const Event = union(enum) {
    output: struct { offset: u32, len: u32 },
    resize: core.TerminalSize,
};

/// Removes `a=q,t=f` queries the sink answered from `bytes`, so the emulator
/// never sees a file query it would refuse. Returns `bytes` untouched when
/// nothing was answered, otherwise the remaining bytes in `scratch`.
///
/// ```zig
/// const remaining = stripFileQueries(bytes, &pipeline.scratch, sink);
/// ```
pub fn stripFileQueries(bytes: []const u8, scratch: []u8, sink: anytype) []const u8 {
    var kept: usize = 0;
    var copied_until: usize = 0;
    var search_from: usize = 0;
    var stripped = false;
    while (std.mem.indexOfPos(u8, bytes, search_from, "\x1b_G")) |start| {
        const terminator = std.mem.indexOfPos(u8, bytes, start + 3, "\x1b\\") orelse break;
        const end = terminator + 2;
        search_from = end;
        const command = bytes[start + 3 .. terminator];
        const separator = std.mem.indexOfScalar(u8, command, ';') orelse continue;
        const query = parseFileQueryControl(command[0..separator]) orelse continue;
        if (separator + 1 == command.len) {
            continue;
        }
        const handled = sink.observeFileQuery(.{
            .bytes = bytes[start..end],
            .encoded_path = command[separator + 1 ..],
            .image_id = query.image_id,
            .byte_len = query.byte_len,
        });
        if (!handled) {
            continue;
        }
        const run = bytes[copied_until..start];
        @memcpy(scratch[kept..][0..run.len], run);
        kept += run.len;
        copied_until = end;
        stripped = true;
    }
    if (!stripped) {
        return bytes;
    }
    const tail = bytes[copied_until..];
    @memcpy(scratch[kept..][0..tail.len], tail);
    return scratch[0 .. kept + tail.len];
}

fn parseFileQueryControl(control: []const u8) ?FileQueryControl {
    var image_id: ?u32 = null;
    var format: ?Format = null;
    var width: ?u32 = null;
    var height: ?u32 = null;
    var query = false;
    var file = false;
    var fields = ControlFields.init(control);
    while (fields.next() catch return null) |field| {
        const value = field.value;
        switch (field.key) {
            'a' => {
                if (query or !std.mem.eql(u8, value, "q")) {
                    return null;
                }

                query = true;
            },
            't' => {
                if (file or !std.mem.eql(u8, value, "f")) {
                    return null;
                }

                file = true;
            },
            'i' => image_id = ControlFields.uniqueId(image_id, value) orelse return null,
            'f' => {
                if (format != null) {
                    return null;
                }

                format = Format.parse(value) orelse return null;
            },
            's' => width = ControlFields.uniqueId(width, value) orelse return null,
            'v' => height = ControlFields.uniqueId(height, value) orelse return null,
            'q' => {},
            else => return null,
        }
    }

    if (!query or !file) {
        return null;
    }

    const byte_len = (format orelse Format.rgba).byteLen(width orelse return null, height orelse return null) orelse return null;
    return .{
        .image_id = image_id orelse return null,
        .byte_len = byte_len,
    };
}

pub fn filterAtomicSharedFrames(input: FilterInput, sink: anytype, availability: anytype) FilterStats {
    const bytes = input.bytes;
    const storage_limit = input.storage_limit;

    var emitted_until: usize = 0;
    var search_from: usize = 0;
    var filtered: FilterStats = .{};

    while (findSharedFrame(bytes, search_from)) |first| {
        var selected: [core.max_placements_per_pane]SelectedSharedFrame = undefined;
        var selected_count: usize = 0;
        var group_end = first.end;
        var overflow = !recordSharedFrame(&selected, &selected_count, first);
        while (sharedFrameAt(bytes, group_end)) |frame| {
            if (!recordSharedFrame(&selected, &selected_count, frame)) {
                overflow = true;
            }
            group_end = frame.end;
        }

        if (!overflow) {
            for (selected[0..selected_count]) |*entry| {
                var recent = entry.recent_count;
                while (recent != 0) {
                    recent -= 1;
                    const frame = sharedFrameAt(bytes, entry.recent_starts[recent]) orelse
                        unreachable;
                    if (!availability.available(frameResource(bytes, frame, storage_limit))) {
                        continue;
                    }
                    entry.start = frame.start;
                    break;
                }
            }

            observeNonEmpty(sink, bytes[emitted_until..first.start]);
            var frame_start = first.start;
            while (frame_start < group_end) {
                const frame = sharedFrameAt(bytes, frame_start) orelse unreachable;
                const chosen = selectedFrameStart(selected[0..selected_count], frame.key);
                if (chosen == frame.start) {
                    // A sink that loads the object itself skips the parser's
                    // copy; otherwise the emulator parses the command as is.
                    const direct = sink.observeSharedFrame(.{
                        .bytes = bytes[frame.start..frame.end],
                        .apc_start = frame.apc_start - frame.start,
                        .apc_end = frame.apc_end - frame.start,
                        .encoded_name = bytes[frame.payload_start..frame.payload_end],
                        .image_id = frame.key.image_id,
                        .placement_id = frame.key.placement_id,
                        .format = frame.format,
                        .width = frame.width,
                        .height = frame.height,
                        .byte_len = frame.byte_len,
                        .medium = frame.medium,
                    });
                    if (direct) {
                        filtered.direct +|= 1;
                        filtered.file +|= @intFromBool(frame.medium == .file);
                        filtered.forwarded +|= 1;
                    } else if (frame.medium == .file) {
                        // The emulator refuses file media; the pane keeps its
                        // current image for this batch.
                        filtered.unavailable +|= 1;
                    } else {
                        sink.observe(bytes[frame.start..frame.end]);
                        filtered.forwarded +|= 1;
                    }
                } else {
                    // Ghostty unlinks every shared object it opens, and the
                    // child leaves that to the terminal: a frame nobody reads
                    // is released the same way, or its object outlives it.
                    availability.release(frameResource(bytes, frame, storage_limit));
                    if (frame.wrapped) {
                        sink.observe(cursor_save);
                    }

                    // With no chosen frame, none of this placement survived
                    // the availability probe; the pane keeps its stale image
                    // this batch.
                    if (chosen == null) {
                        filtered.unavailable +|= 1;
                    } else {
                        filtered.discarded +|= 1;
                    }
                }
                frame_start = frame.end;
            }
            emitted_until = group_end;
        }
        search_from = group_end;
    }

    observeNonEmpty(sink, bytes[emitted_until..]);
    return filtered;
}

fn frameResource(bytes: []const u8, frame: SharedFrame, limit: usize) FrameResource {
    return .{
        .encoded_name = bytes[frame.payload_start..frame.payload_end],
        .byte_len = frame.byte_len,
        .limit = limit,
        .medium = frame.medium,
    };
}

fn observeNonEmpty(sink: anytype, bytes: []const u8) void {
    if (bytes.len != 0) {
        sink.observe(bytes);
    }
}

fn recordSharedFrame(selected: []SelectedSharedFrame, selected_count: *usize, frame: SharedFrame) bool {
    for (selected[0..selected_count.*]) |*entry| {
        if (!std.meta.eql(entry.key, frame.key)) {
            continue;
        }
        if (entry.recent_count == entry.recent_starts.len) {
            std.mem.copyForwards(
                usize,
                entry.recent_starts[0 .. entry.recent_starts.len - 1],
                entry.recent_starts[1..],
            );
            entry.recent_count -= 1;
        }
        entry.recent_starts[entry.recent_count] = frame.start;
        entry.recent_count += 1;
        return true;
    }
    if (selected_count.* == selected.len) {
        return false;
    }
    selected[selected_count.*] = .{
        .key = frame.key,
        .recent_count = 1,
    };
    selected[selected_count.*].recent_starts[0] = frame.start;
    selected_count.* += 1;
    return true;
}

fn selectedFrameStart(selected: []const SelectedSharedFrame, key: SharedFrameKey) ?usize {
    for (selected) |entry| if (std.meta.eql(entry.key, key)) return entry.start;
    return null;
}

pub fn sharedFrameAvailable(resource: FrameResource) bool {
    if (resource.byte_len > resource.limit) {
        return false;
    }
    if (comptime builtin.os.tag == .windows or builtin.abi.isAndroid() or !builtin.link_libc) {
        return false;
    }

    var buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    const name = shared_transfer.decodeChildName(resource.encoded_name, &buffer) orelse return false;
    const fd = std.c.shm_open(
        name,
        @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDONLY })),
        @as(u16, 0),
    );
    if (std.posix.errno(fd) != .SUCCESS) {
        return false;
    }
    _ = std.c.close(fd);
    return true;
}

fn findSharedFrame(bytes: []const u8, from: usize) ?SharedFrame {
    var search_from = from;
    while (std.mem.indexOfPos(u8, bytes, search_from, atomic_shared_prefix)) |start| {
        const saved = start -| cursor_save.len;
        if (saved >= from and std.mem.startsWith(u8, bytes[saved..], cursor_save)) {
            if (sharedFrameAt(bytes, saved)) |frame| {
                return frame;
            }
        }

        if (sharedFrameAt(bytes, start)) |frame| {
            return frame;
        }
        search_from = start + atomic_shared_prefix.len;
    }
    return null;
}

// The frame at `start`: an envelope, or one wrapped in DECSC and DECRC.
fn sharedFrameAt(bytes: []const u8, start: usize) ?SharedFrame {
    if (start > bytes.len) {
        return null;
    }

    const wrapped = std.mem.startsWith(u8, bytes[start..], cursor_save);
    const envelope = if (wrapped) start + cursor_save.len else start;
    if (!std.mem.startsWith(u8, bytes[envelope..], atomic_shared_prefix)) {
        return null;
    }
    const command_start = envelope + atomic_shared_prefix.len;
    const terminator = std.mem.indexOfPos(u8, bytes, command_start, "\x1b\\") orelse return null;
    if (!std.mem.startsWith(u8, bytes[terminator..], atomic_shared_suffix)) {
        return null;
    }
    const envelope_end = terminator + atomic_shared_suffix.len;
    if (wrapped and !std.mem.startsWith(u8, bytes[envelope_end..], cursor_restore)) {
        return null;
    }
    const command = bytes[command_start..terminator];
    const separator = std.mem.indexOfScalar(u8, command, ';') orelse return null;
    const parsed = parseSharedFrameControl(command[0..separator]) orelse return null;
    if (separator + 1 == command.len) {
        return null;
    }
    return .{
        .start = start,
        .end = if (wrapped) envelope_end + cursor_restore.len else envelope_end,
        .wrapped = wrapped,
        .apc_start = command_start - "\x1b_G".len,
        .apc_end = terminator + "\x1b\\".len,
        .payload_start = command_start + separator + 1,
        .payload_end = terminator,
        .key = parsed.key,
        .byte_len = parsed.byte_len,
        .format = parsed.format,
        .width = parsed.width,
        .height = parsed.height,
        .medium = parsed.medium,
    };
}

fn parseSharedFrameControl(control: []const u8) ?SharedFrameControl {
    var image_id: ?u32 = null;
    var placement_id: ?u32 = null;
    var format: ?Format = null;
    var width: ?u32 = null;
    var height: ?u32 = null;
    var transmit = false;
    var medium: ?Medium = null;
    var cursor_static = false;
    var quiet = false;
    var fields = ControlFields.init(control);
    while (fields.next() catch return null) |field| {
        const value = field.value;
        switch (field.key) {
            'a' => {
                if (transmit or !std.mem.eql(u8, value, "T")) {
                    return null;
                }
                transmit = true;
            },
            't' => {
                if (medium != null) {
                    return null;
                }
                medium = if (std.mem.eql(u8, value, "s")) .shared else if (std.mem.eql(u8, value, "f")) .file else return null;
            },
            'i' => image_id = ControlFields.uniqueId(image_id, value) orelse return null,
            'p' => placement_id = ControlFields.uniqueId(placement_id, value) orelse return null,
            'f' => {
                if (format != null) {
                    return null;
                }

                format = Format.parse(value) orelse return null;
            },
            's' => width = ControlFields.uniqueId(width, value) orelse return null,
            'v' => height = ControlFields.uniqueId(height, value) orelse return null,
            'C' => {
                if (cursor_static or !std.mem.eql(u8, value, "1")) {
                    return null;
                }
                cursor_static = true;
            },
            'q' => {
                if (quiet or !std.mem.eql(u8, value, "2")) {
                    return null;
                }

                quiet = true;
            },
            // Chunked transmissions carry ordering state and are never folded.
            // Any other key (offsets, sizes, crops, z) means the frame is
            // not the plain full replacement this fold understands.
            else => return null,
        }
    }
    if (!transmit or !cursor_static or !quiet) {
        return null;
    }
    const image = image_id orelse return null;
    const placement = placement_id orelse return null;
    const pixel_format = format orelse return null;
    const byte_len = pixel_format.byteLen(width orelse return null, height orelse return null) orelse return null;
    return .{
        .key = .{ .image_id = image, .placement_id = placement },
        .byte_len = byte_len,
        .format = pixel_format,
        .width = width.?,
        .height = height.?,
        .medium = medium orelse return null,
    };
}

/// Stable identity for a child placement. Anonymous placements use Ghostty's
/// internal namespace; explicit child IDs use the exterior namespace. Adding
/// one reserves zero as the invalid value in Telar's wire vocabulary.
///
/// ```zig
/// const virtual_id = placementVirtualId(key);
/// ```
pub fn placementVirtualId(key: vt.kitty.graphics.ImageStorage.PlacementKey) u64 {
    const tag: u64 = switch (key.placement_id.tag) {
        .internal => 0,
        .external => 1,
    };
    return ((tag << 32) | key.placement_id.id) + 1;
}

/// Converts Ghostty's pinned placement into pane-relative coordinates.
///
/// Both the runtime sync path and the reduced terminal-browser example use
/// this adapter. Keeping one implementation matters here: a second geometry
/// conversion in the example could hide the production bug it is meant to
/// isolate.
///
/// ```zig
/// const placement = placementValue(terminal, source) orelse return;
/// ```
pub fn placementValue(terminal: *vt.Terminal, source_value: PlacementSource) ?core.Placement {
    const pin = switch (source_value.placement.location) {
        .pin => |value| value,
        .virtual => return null,
    };

    if (pin.garbage) {
        return null;
    }

    const pages = &terminal.screens.active.pages;
    const screen_point = pages.pointFromPin(.screen, pin.*) orelse return null;
    const viewport = pages.pointFromPin(.screen, pages.getTopLeft(.viewport)) orelse return null;
    const source = source_value.placement.sourceRect(source_value.image);
    return .{
        .key = .{ .image_id = source_value.image.id, .generation = source_value.image.generation },
        .virtual_id = placementVirtualId(source_value.key),
        .placement_id = switch (source_value.key.placement_id.tag) {
            .internal => 0,
            .external => source_value.key.placement_id.id,
        },
        .x = @intCast(screen_point.screen.x),
        .y = @as(i32, @intCast(screen_point.screen.y)) -
            @as(i32, @intCast(viewport.screen.y)),
        .source_x = source.x,
        .source_y = source.y,
        .source_width = source.width,
        .source_height = source.height,
        .columns = source_value.placement.columns,
        .rows = source_value.placement.rows,
        .offset_x = source_value.placement.x_offset,
        .offset_y = source_value.placement.y_offset,
        .z_index = source_value.placement.z,
    };
}

pub fn vtResize(size: core.TerminalSize) vt.Terminal.Resize {
    return .{
        .cols = size.cols,
        .rows = size.rows,
        .cell_size_px = if (size.cell_width_px != 0 and size.cell_height_px != 0) .{
            .width = size.cell_width_px,
            .height = size.cell_height_px,
        } else null,
    };
}

const SelectedSharedFrame = struct {
    key: SharedFrameKey,
    // SAFETY: Frame selection fills retained starts before publishing the entry; fallback scans only recent_count starts.
    recent_starts: [8]usize = undefined,
    recent_count: u4,
    start: ?usize = null,
};

const FilterStats = struct {
    /// Terminal-browser publishes complete shared-memory replacements inside one
    /// synchronized-output envelope. A busy media actor only needs the newest
    /// replacement for each placement; mapping older frames would spend the pane
    /// quota and then overwrite the result. Bytes outside this exact shape remain
    /// untouched and therefore keep Ghostty as the sole terminal emulator.
    discarded: u64 = 0,
    unavailable: u64 = 0,
    forwarded: u64 = 0,
    /// The subset of `forwarded` the sink loaded without the parser.
    direct: u64 = 0,
    /// The subset of `direct` whose pixels came from a child file.
    file: u64 = 0,
};

const FilterInput = struct {
    bytes: []const u8,
    storage_limit: usize,
};

const FileQueryControl = struct {
    image_id: u32,
    byte_len: usize,
};
