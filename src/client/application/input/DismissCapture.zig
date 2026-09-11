const DismissCapture = @This();
const source_namespace = @import("attachment_prompt.zig");
const DismissEffects = @import("DismissEffects.zig");
const attachments = @import("../../attachments/root.zig");
const RemovalCommand = @import("RemovalCommand.zig");
events: [3]source_namespace.Event = undefined,
count: usize = 0,
layout_changed: bool = false,
plan_available: bool = true,

pub fn effects(capture: *DismissCapture) DismissEffects {
    return .{ .context = capture, .plan = plan, .deliver = deliver, .remove = remove };
}

fn append(capture: *DismissCapture, event: source_namespace.Event) void {
    capture.events[capture.count] = event;
    capture.count += 1;
}

fn plan(raw_context: *anyopaque, _: attachments.Id) ?RemovalCommand {
    const capture: *DismissCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.plan);
    if (!capture.plan_available) {
        return null;
    }

    return .{
        .pane_id = @enumFromInt(7),
        .marker = .{ .direction = .left, .steps = 1, .deletion = .backward },
    };
}

fn deliver(raw_context: *anyopaque, _: RemovalCommand) !void {
    const capture: *DismissCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.deliver);
}

fn remove(raw_context: *anyopaque, _: attachments.Id) ?bool {
    const capture: *DismissCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.remove);

    return capture.layout_changed;
}
