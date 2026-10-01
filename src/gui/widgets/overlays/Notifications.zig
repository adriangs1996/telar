//! Native notification composition and bounded, disposable stack motion.
const shared_model = @import("model");
const client = @import("telar-client");
const Canvas = @import("../Canvas.zig");
const animate = @import("animate");
const Clock = animate.FrameClock;
const Card = @import("NotificationCard.zig");
const data = @import("model");
const Transition = animate.Transition;
const Hits = @import("NotificationHits.zig");
const Notifications = @This();
const GenericWidgetList = @import("../GenericWidgetList.zig").Type;

pub const max_visible = Hits.max_visible;
pub const Cards = GenericWidgetList(Card, max_visible);
motions: [shared_model.notifications.max_items]Motion = @splat(.{}),

/// Returns a bounded list of measured cards without emitting quads. Its text
/// borrows the projection until the caller draws the list.
/// Example: `var cards = try notifications.prepare(canvas, projection);`
pub fn prepare(self: *Notifications, canvas: *Canvas, projection: client.Projection) !Cards {
    var result: Cards = .{};
    const host = canvas.rect(projection.geometry.area);
    const margin = canvas.chrome.px(16);
    const width = @min(canvas.chrome.px(360), host.width - 2 * margin);
    if (width < canvas.chrome.px(160) or host.height < canvas.chrome.px(96)) {
        self.motions = @splat(.{});
        return result;
    }

    var used: [shared_model.notifications.max_items]bool = @splat(false);
    var y = host.y + margin;
    var painted: usize = 0;
    var cards: [max_visible]Card = undefined;
    for (0..projection.notifications.count) |index| {
        if (painted == max_visible) {
            break;
        }

        const item = projection.notifications.itemAt(index).?;
        if (targetVisible(projection, item.target)) {
            continue;
        }

        if (item.transition_position_ns == 0 and item.phase == .exiting) {
            continue;
        }

        var card: Card = .{ .item = item, .bounds = .{ .x = host.x + host.width - margin - width, .y = y, .width = width, .height = 0 }, .clip = host };
        try card.measure(canvas);
        if (y + card.bounds.height > host.y + host.height - margin) {
            break;
        }

        const opacity = visibility(item, canvas.animation);
        card.opacity = opacity;
        if (opacity == 0 and item.phase == .exiting) {
            continue;
        }

        if (canvas.animation) |clock| {
            if (self.motion(item.id, y)) |slot| {
                used[slot] = true;
                card.bounds.y = self.motions[slot].position(y, clock);
            }
        }

        card.bounds.x += canvas.chrome.px(12) * (1 - opacity);
        card.bounds.y += canvas.chrome.px(6) * (1 - opacity);
        y += card.bounds.height + canvas.chrome.px(10);
        cards[painted] = card;
        painted += 1;
    }

    // Newer cards stay above older cards while the stack changes position.
    while (painted > 0) {
        painted -= 1;
        const card = &cards[painted];
        if (card.opacity == 0) {
            continue;
        }

        result.append(card.*);
    }

    for (&self.motions, used) |*motion_state, seen| {
        if (!seen) {
            motion_state.* = .{};
        }
    }

    return result;
}

fn motion(self: *Notifications, id: shared_model.notifications.Id, y: f32) ?usize {
    for (self.motions, 0..) |entry, index| {
        if (entry.id == id) {
            return index;
        }
    }

    for (&self.motions, 0..) |*entry, index| {
        if (entry.id == .invalid) {
            entry.* = .{ .id = id, .from = y, .to = y };
            return index;
        }
    }

    // Repeated failed preparations can retain an older set until pruning.
    // A new card uses its final position for this frame if the slots are full.
    return null;
}

fn visibility(item: *const shared_model.NotificationItem, clock: ?*Clock) f32 {
    var sampled = item.*;
    if (clock) |frame| {
        if (sampled.phase == .entering) {
            _ = sampled.advanceEntering(frame.now_ns);
        }
        if (sampled.phase == .visible and frame.now_ns >= sampled.expires_at_ns) {
            _ = sampled.beginExit(sampled.expires_at_ns);
        }
        if (sampled.phase == .exiting) {
            _ = sampled.advanceExiting(frame.now_ns);
        }

        if (sampled.phase == .entering or (sampled.phase == .exiting and sampled.transition_position_ns > 0)) {
            frame.requestAt(sampled.nextDeadline(frame.now_ns, frame.interval_ns));
        }
    }

    const t = @as(f32, @floatFromInt(sampled.transition_position_ns)) / @as(f32, @floatFromInt(shared_model.notifications.transition_duration_ns));
    return t * t * (3 - 2 * t);
}

/// Suppresses a notice whose target pane is already visible in the active tab.
/// Example: `if (Notifications.targetVisible(projection, item.target)) continue;`
pub fn targetVisible(projection: client.Projection, target: shared_model.notifications.Target) bool {
    const pane_id = switch (target) {
        .focus_pane => |id| id,
        else => return false,
    };
    const layout = projection.layout orelse return false;
    return layout.find(pane_id) != null;
}

/// Disposable stack position, keyed by semantic notification identity.
const Motion = struct {
    id: data.notifications.Id = .invalid,
    from: f32 = 0,
    to: f32 = 0,
    transition: Transition = .{ .from = 0, .to = 1, .started_ns = 0, .duration_ns = 180_000_000 },

    /// Retargets from the sampled position when another card arrives or leaves.
    /// Example: `const y = motion.position(target_y, clock);`
    pub fn position(self: *Motion, target: f32, clock: *Clock) f32 {
        if (self.to != target) {
            self.from = self.value(clock.now_ns);
            self.to = target;
            self.transition.started_ns = clock.now_ns;
        }

        _ = clock.sample(self.transition);
        return self.value(clock.now_ns);
    }

    fn value(self: Motion, now_ns: u64) f32 {
        const t = self.transition.value(now_ns);
        return self.from + (self.to - self.from) * t * t * (3 - 2 * t);
    }
};
