//! Bounded, disposable scrolling for a native list in device pixels.
const data = @import("model");
const PixelScroll = @This();

scroll: u16 = 0,
maximum_scroll: u16 = 0,
step: u16 = 0,
remainder: f64 = 0,

/// Constrains the offset to the current list geometry.
/// Example: `scroll.setBounds(pitch, total - viewport.height);`
pub fn setBounds(self: *PixelScroll, step: f32, maximum: f32) void {
    self.step = @intFromFloat(@min(65535, @max(0, step)));
    self.maximum_scroll = @intFromFloat(@min(65535, @ceil(@max(0, maximum))));
    self.scroll = @min(self.scroll, self.maximum_scroll);
}

/// Preserves the offset until the list is visible again.
/// Example: `scroll.hide();`
pub fn hide(self: *PixelScroll) void {
    self.maximum_scroll = 0;
    self.remainder = 0;
}

/// Discards fractional movement when a trackpad gesture begins or is cancelled.
/// Example: `scroll.resetGesture();`
pub fn resetGesture(self: *PixelScroll) void {
    self.remainder = 0;
}

/// Moves one item without changing client navigation.
/// Example: `if (scroll.wheel(.scroll_down)) chrome.invalidate();`
pub fn wheel(self: *PixelScroll, kind: data.Mouse.Kind) bool {
    return self.scrollBy(switch (kind) {
        .scroll_up => -@as(f64, @floatFromInt(self.step)),
        .scroll_down => @as(f64, @floatFromInt(self.step)),
        else => 0,
    });
}

/// Accumulates fractional trackpad movement independently for each list.
/// Example: `if (scroll.scrollBy(delta_pixels)) chrome.invalidate();`
pub fn scrollBy(self: *PixelScroll, delta: f64) bool {
    self.remainder += delta;
    const movement = @trunc(self.remainder);
    self.remainder -= movement;
    const next: u16 = @intFromFloat(@max(0, @min(@as(f64, @floatFromInt(self.maximum_scroll)), @as(f64, @floatFromInt(self.scroll)) + movement)));
    if (next == self.scroll) {
        return false;
    }

    self.scroll = next;
    return true;
}

/// Reveals an item after navigation or resizing without pinning manual scroll.
/// Example: `scroll.reveal(.{ top, bottom }, viewport.height);`
pub fn reveal(self: *PixelScroll, item: [2]f32, height: f32) void {
    const offset: f32 = @floatFromInt(self.scroll);
    const next = if (item[0] < offset or item[1] - item[0] > height) item[0] else if (item[1] > offset + height) item[1] - height else offset;
    self.scroll = @intFromFloat(@max(0, @min(@as(f32, @floatFromInt(self.maximum_scroll)), @ceil(next))));
}
