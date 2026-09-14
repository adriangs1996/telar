//! Native notification composition and bounded, disposable stack motion.
const client = @import("telar-client");
const Canvas = @import("../chrome/Canvas.zig");
const Clock = @import("../animation/FrameClock.zig");
const Card = @import("NotificationCard.zig");
const Motion = @import("NotificationMotion.zig");
const Hits = @import("NotificationHits.zig");
const Notifications = @This();
const GenericWidgetList = @import("../widgets/GenericWidgetList.zig").Type;

pub const max_visible = Hits.max_visible;
pub const Cards = GenericWidgetList(Card, max_visible);
motions: [client.max_items]Motion = @splat(.{}),

/// Returns a bounded list of measured cards without emitting quads. Its text
/// borrows the projection until the caller draws the list.
/// Example: `var cards = try notifications.prepare(canvas, projection);`
pub fn prepare(notifications: *Notifications, canvas: *Canvas, projection: client.Projection) !Cards {
    var result: Cards = .{};
    const host = canvas.rect(projection.geometry.area);
    const margin = canvas.chrome.px(16);
    const width = @min(canvas.chrome.px(360), host.width - 2 * margin);
    if (width < canvas.chrome.px(160) or host.height < canvas.chrome.px(96)) {
        notifications.motions = @splat(.{});
        return result;
    }

    var used: [client.max_items]bool = @splat(false);
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
            if (notifications.motion(item.id, y)) |slot| {
                used[slot] = true;
                card.bounds.y = notifications.motions[slot].position(y, clock);
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

        try result.append(card.*);
    }

    for (&notifications.motions, used) |*motion_state, seen| {
        if (!seen) {
            motion_state.* = .{};
        }
    }

    return result;
}

fn motion(notifications: *Notifications, id: client.Id, y: f32) ?usize {
    for (notifications.motions, 0..) |entry, index| {
        if (entry.id == id) {
            return index;
        }
    }

    for (&notifications.motions, 0..) |*entry, index| {
        if (entry.id == .invalid) {
            entry.* = .{ .id = id, .from = y, .to = y };
            return index;
        }
    }

    // Repeated failed preparations can retain an older set until pruning.
    // A new card uses its final position for this frame if the slots are full.
    return null;
}

fn visibility(item: *const client.NotificationItem, clock: ?*Clock) f32 {
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
            frame.requestAt(sampled.nextDeadline(frame.now_ns, Clock.frame_interval_ns));
        }
    }

    const t = @as(f32, @floatFromInt(sampled.transition_position_ns)) / @as(f32, @floatFromInt(client.transition_duration_ns));
    return t * t * (3 - 2 * t);
}

/// Suppresses a notice whose target pane is already visible in the active tab.
/// Example: `if (Notifications.targetVisible(projection, item.target)) continue;`
pub fn targetVisible(projection: client.Projection, target: client.NotificationTarget) bool {
    const pane_id = switch (target) {
        .focus_pane => |id| id,
        else => return false,
    };
    const model = projection.model orelse return false;
    var layout: client.LayoutSnapshot = .{};
    model.layout.snapshot(projection.geometry.area, &layout);
    return layout.find(pane_id) != null;
}
