//! Bounded, disposable scrolling for a native list in device pixels.
const client = @import("telar-client");
const PixelScroll = @This();

scroll: u16 = 0,
maximum_scroll: u16 = 0,
step: u16 = 0,
remainder: f64 = 0,

/// Constrains the offset to the current list geometry.
/// Example: `scroll.setBounds(pitch, total - viewport.height);`
pub fn setBounds(state: *PixelScroll, step: f32, maximum: f32) void {
    state.step = @intFromFloat(@min(65535, @max(0, step)));
    state.maximum_scroll = @intFromFloat(@min(65535, @ceil(@max(0, maximum))));
    state.scroll = @min(state.scroll, state.maximum_scroll);
}

/// Preserves the offset until the list is visible again.
/// Example: `scroll.hide();`
pub fn hide(state: *PixelScroll) void {
    state.maximum_scroll = 0;
    state.remainder = 0;
}

/// Discards fractional movement when a trackpad gesture begins or is cancelled.
/// Example: `scroll.resetGesture();`
pub fn resetGesture(state: *PixelScroll) void {
    state.remainder = 0;
}

/// Moves one item without changing client navigation.
/// Example: `if (scroll.wheel(.scroll_down)) chrome.invalidate();`
pub fn wheel(state: *PixelScroll, kind: client.Mouse.Kind) bool {
    return state.scrollBy(switch (kind) {
        .scroll_up => -@as(f64, @floatFromInt(state.step)),
        .scroll_down => @as(f64, @floatFromInt(state.step)),
        else => 0,
    });
}

/// Accumulates fractional trackpad movement independently for each list.
/// Example: `if (scroll.scrollBy(delta_pixels)) chrome.invalidate();`
pub fn scrollBy(state: *PixelScroll, delta: f64) bool {
    state.remainder += delta;
    const movement = @trunc(state.remainder);
    state.remainder -= movement;
    const next: u16 = @intFromFloat(@max(0, @min(@as(f64, @floatFromInt(state.maximum_scroll)), @as(f64, @floatFromInt(state.scroll)) + movement)));
    if (next == state.scroll) {
        return false;
    }

    state.scroll = next;
    return true;
}

/// Reveals an item after navigation or resizing without pinning manual scroll.
/// Example: `scroll.reveal(.{ top, bottom }, viewport.height);`
pub fn reveal(state: *PixelScroll, item: [2]f32, height: f32) void {
    const offset: f32 = @floatFromInt(state.scroll);
    const next = if (item[0] < offset or item[1] - item[0] > height) item[0] else if (item[1] > offset + height) item[1] - height else offset;
    state.scroll = @intFromFloat(@max(0, @min(@as(f32, @floatFromInt(state.maximum_scroll)), @ceil(next))));
}
