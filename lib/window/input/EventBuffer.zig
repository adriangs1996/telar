const std = @import("std");
const input = @import("Input.zig");
const Input = input.Input;
const EventBuffer = @This();

const capacity: usize = 1024;
const byte_capacity = 2 * Input.max_text_bytes;
const release_reserve = 260;
const Slot = struct { value: Input, reserved: usize };

// SAFETY: append writes a complete slot before increasing len; next refuses an empty queue and retire only accesses a borrowed live slot.
items: [capacity]Slot = undefined,
// SAFETY: append copies payload bytes before publishing their slot; next returns only that payload's slice until retire releases it.
bytes: [byte_capacity]u8 = undefined,
head: usize = 0,
len: usize = 0,
write: usize = 0,
used: usize = 0,
borrowed: bool = false,
failure: ?anyerror = null,

/// Copies native payloads before their callback returns. Ordinary input leaves
/// slots for 256 physical key releases, pointer releases and focus loss, so an
/// input burst cannot consume the space needed to release an accepted gesture.
pub fn append(self: *EventBuffer, value: Input) bool {
    const release = switch (value) {
        .key => |key| key.phase == .release,
        .text => |text| text.phase == .release,
        .pointer => |pointer| pointer.kind == .release or pointer.kind == .leave,
        .focus => |focused| !focused,
        .composition => |composition| composition.cancel,
        else => false,
    };
    if (self.len >= (if (release) capacity else capacity - release_reserve)) {
        self.failure = error.NativeInputFull;
        return false;
    }

    if (self.len == 0) {
        self.write = 0;
    }

    const payload = value.payload();
    const padding = if (self.write + payload.len > byte_capacity) byte_capacity - self.write else 0;
    const reserved = padding + payload.len;
    const spare: usize = if (release) 0 else Input.max_composition_bytes;
    if (reserved + spare > byte_capacity - self.used) {
        self.failure = error.InputPoolFull;
        return false;
    }

    const offset = if (padding != 0) 0 else self.write;
    @memcpy(self.bytes[offset..][0..payload.len], payload);
    self.items[(self.head + self.len) % capacity] = .{
        .value = value.withPayload(self.bytes[offset..][0..payload.len]),
        .reserved = reserved,
    };
    self.write = (offset + payload.len) % byte_capacity;
    self.used += reserved;
    self.len += 1;
    return true;
}

/// Returned slices stay valid until the next getNextEvent call. Retirement is
/// explicit so native callbacks between calls cannot overwrite borrowed text.
pub fn next(self: *EventBuffer) ?Input {
    std.debug.assert(!self.borrowed);
    if (self.len == 0) {
        return null;
    }

    self.borrowed = true;
    return self.items[self.head].value;
}

pub fn retire(self: *EventBuffer) void {
    if (!self.borrowed) {
        return;
    }

    self.used -= self.items[self.head].reserved;
    self.head = (self.head + 1) % capacity;
    self.len -= 1;
    self.borrowed = false;
}
