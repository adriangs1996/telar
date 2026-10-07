//! Ordered, bounded input storage. Owns payload lifetimes and release recovery.
const Window = @import("telar-window");
const input_item = @import("input_item.zig");
const std = @import("std");
const core = @import("telar-core");
const event_types = Window;
const ReleaseRecovery = @import("input/ReleaseRecovery.zig");
const PasteChunk = @import("PasteChunk.zig");
const KeyInput = @FieldType(Window.Input, "key");
const GenericEventPool = @import("input/GenericEventPool.zig").Type;
const InputQueue = @This();
const PointerStamp = @import("input/PointerStamp.zig");

pub const max_paste_bytes = event_types.Input.max_text_bytes;
const capacity = 1024;
/// Scalars a committed text takes one ring entry each; a longer text is
/// held whole in the large pool.
const inline_text_scalars = 64;
/// Ring entries a native paste takes as chunks; a longer paste is held
/// whole in the large pool.
const inline_paste_items = 64;
/// Bytes and slots of the pool holding widget text, compositions and
/// accessibility edits.
const small_event_bytes = 4096;
const small_event_slots = 8;
/// Slots of the pool holding clipboard results and held texts and pastes;
/// held ones leave `clipboard_spare` for a clipboard result.
const large_event_slots = 3;
const clipboard_spare = 1;
const SmallEvents = GenericEventPool(small_event_bytes, small_event_slots);
const LargeEvents = GenericEventPool(max_paste_bytes, large_event_slots);
pub const queue_limit = core.Limit.declare("gui.input.queue_capacity", "input events", capacity);
pub const small_limit = core.Limit.declare("gui.input.event_pool_bytes", "text bytes", small_event_bytes);
pub const small_slots_limit = core.Limit.declare("gui.input.small_events", "held events", small_event_slots);
pub const large_slots_limit = core.Limit.declare("gui.input.large_events", "held payloads", large_event_slots);

// SAFETY: push assigns a ring item before increasing len; front and consume require queued items.
items: [capacity]input_item.Item = undefined,
head: usize = 0,
len: usize = 0,
recovery: ReleaseRecovery = .{},
small_events: SmallEvents = .{},
large_events: LargeEvents = .{},
/// Both pools' payloads, reserved once by `init` and written only by the
/// bytes an event copies, so an unused pool costs no resident memory.
storage: []u8 = &.{},

/// Builds the queue where it lives: its ring stays unwritten until events
/// arrive. Example: `try gui.model.input_queue.init(gpa);`
pub fn init(self: *InputQueue, gpa: std.mem.Allocator) !void {
    const storage = try gpa.alloc(u8, SmallEvents.storage_bytes + LargeEvents.storage_bytes);
    self.head = 0;
    self.len = 0;
    self.recovery = .{};
    self.small_events = .init(storage[0..SmallEvents.storage_bytes]);
    self.large_events = .init(storage[SmallEvents.storage_bytes..]);
    self.storage = storage;
}

/// Example: `gui.model.input_queue.deinit(gpa);`
pub fn deinit(self: *InputQueue, gpa: std.mem.Allocator) void {
    gpa.free(self.storage);
    self.storage = &.{};
}

/// Copies borrowed payloads atomically into bounded storage. Recovery admission
/// requires the owner to invalidate gestures before accepting another event.
/// Example: `const result = try queue.accept(event, stamp);`
pub fn accept(self: *InputQueue, event: event_types.Input, stamp: PointerStamp) !input_item.Admission {
    switch (event) {
        .pointer => |pointer| {
            self.reserve(1) catch |err| {
                if (pointer.kind != .release and pointer.kind != .leave) {
                    return err;
                }

                self.requestRecovery();
                return .recovery;
            };
            self.push(.{ .pointer = .{ .event = pointer, .geometry_revision = stamp.geometry_revision, .gesture_revision = stamp.gesture_revision } });
        },
        .text => |text| {
            if (text.target_id != 0 and text.phase == .release and text.physical != null) {
                var iterator = (try std.unicode.Utf8View.init(text.bytes)).iterator();
                const bytes = iterator.nextCodepointSlice() orelse return error.InvalidNativeInput;
                if (iterator.nextCodepointSlice() != null) {
                    return error.InvalidNativeInput;
                }

                var key: KeyInput = .{ .code = .{ .char = .{ .bytes = @splat(0), .len = @intCast(bytes.len) } }, .phase = .release, .physical = text.physical, .target_id = text.target_id, .generation = text.generation };
                @memcpy(key.code.char.bytes[0..bytes.len], bytes);
                return self.pushKey(key, .key);
            }

            if (text.target_id != 0) {
                try self.reserve(1);
                self.push(.{ .owned_small = try self.small_events.admit(event) });
                return .accepted;
            }

            const view = try std.unicode.Utf8View.init(text.bytes);
            var iterator = view.iterator();
            var count: usize = 0;
            while (iterator.nextCodepoint() != null) {
                count += 1;
            }

            if (count > inline_text_scalars) {
                try self.reserve(1);
                self.push(.{ .text_block = .{ .slot = try self.large_events.admitLeaving(event, clipboard_spare) } });
                return .accepted;
            }

            self.reserve(count) catch |err| {
                if (count != 1 or text.phase != .release or text.physical == null) {
                    return err;
                }
            };
            var admission: input_item.Admission = .accepted;
            iterator = view.iterator();
            while (iterator.nextCodepointSlice()) |bytes| {
                var key: KeyInput = .{ .code = .{ .char = .{ .bytes = @splat(0), .len = @intCast(bytes.len) } }, .phase = text.phase };
                @memcpy(key.code.char.bytes[0..bytes.len], bytes);
                if (count == 1) {
                    key.physical = text.physical;
                }

                admission = try self.pushKey(key, .text);
            }

            return admission;
        },
        .paste => |text| {
            if (text.len > max_paste_bytes) {
                return error.InputTooLarge;
            }

            if (!std.unicode.utf8ValidateSlice(text)) {
                return error.InvalidUtf8;
            }

            if (text.len == 0) {
                return .accepted;
            }

            var offset: usize = 0;
            var chunks: usize = 0;
            while (offset < text.len) {
                offset += PasteChunk.nextSize(text[offset..]);
                chunks += 1;
            }

            if (chunks + 2 > inline_paste_items) {
                try self.reserve(1);
                self.push(.{ .paste_block = .{ .slot = try self.large_events.admitLeaving(event, clipboard_spare) } });
                return .accepted;
            }

            try self.reserve(chunks + 2);
            self.push(.paste_start);
            offset = 0;
            while (offset < text.len) {
                const count = PasteChunk.nextSize(text[offset..]);
                var chunk: PasteChunk = .{ .len = @intCast(count) };
                @memcpy(chunk.bytes[0..count], text[offset..][0..count]);
                self.push(.{ .paste_text = chunk });
                offset += count;
            }

            self.push(.paste_finish);
        },
        .key => |key| return self.pushKey(key, .key),
        .focus => return error.FocusRequiresHostDispatch,
        .scroll => |scroll| {
            try self.reserve(1);
            self.push(.{ .scroll = .{ .event = scroll, .geometry_revision = stamp.geometry_revision, .gesture_revision = stamp.gesture_revision } });
        },
        .clipboard => {
            try self.reserve(1);
            self.push(.{ .owned_large = try self.large_events.admit(event) });
        },
        .composition => |value| {
            if (value.cancel) {
                self.reserve(1) catch {
                    self.requestRecovery();
                    return .recovery;
                };

                self.push(.{ .composition_cancel = .{ .target_id = value.target_id, .generation = value.generation, .cancel = true } });
                return .accepted;
            }

            try self.reserve(1);
            self.push(.{ .owned_small = try self.small_events.admit(event) });
        },
        .accessibility, .delete_surrounding => {
            try self.reserve(1);
            self.push(.{ .owned_small = try self.small_events.admit(event) });
        },
    }

    return .accepted;
}

/// Borrow the oldest event until it is fully processed. Partial scroll/paste
/// delivery retains the same slot. Example: `const event = input.front() orelse return;`
pub fn front(self: *InputQueue) ?*input_item.Item {
    if (self.len == 0) {
        return null;
    }

    return &self.items[self.head];
}

/// Release owned payload storage only after successful delivery, then advance
/// the ring. Example: `try dispatch(event); input.consume();`
pub fn consume(self: *InputQueue) void {
    std.debug.assert(self.len != 0);
    switch (self.items[self.head]) {
        .owned_small => |index| self.small_events.release(index),
        .owned_large => |index| self.large_events.release(index),
        .text_block, .paste_block => |held| self.large_events.release(held.slot),
        .release_recovery => {
            std.debug.assert(self.recovery.len == 0);
            self.recovery.queued = false;
        },
        else => {},
    }

    self.head = (self.head + 1) % capacity;
    self.len -= 1;
}

fn reserve(self: *const InputQueue, count: usize) !void {
    if (self.recovery.queued or count > (capacity - 1) -| self.len) {
        return error.NativeInputFull;
    }
}

fn pushKey(self: *InputQueue, key: KeyInput, source: enum { key, text }) !input_item.Admission {
    self.reserve(1) catch |err| {
        if (key.phase != .release or key.physical == null) {
            return err;
        }

        self.recovery.retain(key);
        self.requestRecovery();
        return .recovery;
    };

    self.push(switch (source) {
        .key => .{ .key = key },
        .text => .{ .text = .{ .bytes = key.code.char.bytes, .len = key.code.char.len, .phase = key.phase, .physical = key.physical } },
    });

    return .accepted;
}

/// Reserves ordered recovery even when ordinary event admission is saturated.
/// Example: `input.requestRecovery();`
pub fn requestRecovery(self: *InputQueue) void {
    if (self.recovery.queued) {
        return;
    }

    std.debug.assert(self.len < capacity);
    self.push(.release_recovery);
    self.recovery.queued = true;
}

fn push(self: *InputQueue, item: input_item.Item) void {
    self.items[(self.head + self.len) % capacity] = item;
    self.len += 1;
}
