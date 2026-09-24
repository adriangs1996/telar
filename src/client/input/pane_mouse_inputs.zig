//! Encodes pane-relative SGR mouse reports, including exact host pixels.

const pacing = @import("pacing");
const data = @import("model");
const mouse_protocol = @import("mouse_protocol.zig");
const std = @import("std");
const PixelProjection = @import("PixelProjection.zig");
const mouse_protocol_module = @import("mouse_protocol.zig");
const pane_input = @import("../panes/pane_input.zig");
const pane_viewport = @import("../panes/pane_viewport.zig");
const Client = @import("../execution/Client.zig");

/// Projects host pixels into pane coordinates before encoding the report.
/// Example: `const bytes = try pane_mouse_inputs.encodeReport(&buffer, report);`
pub fn encodeReport(buffer: []u8, report: data.ReportEffect) ![]const u8 {
    const command = report.command;
    const plan = report.plan;
    const exact_x: ?u32 = if (plan.protocol.pixels and command.exterior_pixels) exact: {
        const origin = @as(u32, plan.content.x) * command.cell_width_px;
        std.debug.assert(command.event.raw_x >= origin);
        break :exact command.event.raw_x - origin;
    } else null;
    const exact_y: ?u32 = if (plan.protocol.pixels and command.exterior_pixels) exact: {
        const origin = @as(u32, plan.content.y) * command.cell_height_px;
        std.debug.assert(command.event.raw_y >= origin);
        break :exact command.event.raw_y - origin;
    } else null;

    const pixels: ?PixelProjection = if (plan.protocol.pixels) .{
        .cell = .{ .width = command.cell_width_px, .height = command.cell_height_px },
        .exact = if (exact_x != null and exact_y != null) .{ .x = exact_x.?, .y = exact_y.? } else null,
    } else null;

    return mouse_protocol.encodeSgr(buffer, .{
        .event = command.event,
        .pane_position = .{
            .x = command.event.x - plan.content.x,
            .y = command.event.y - plan.content.y,
        },
        .pixels = pixels,
    });
}

test "pane mouse reports preserve exact host pixels relative to pane content" {
    var buffer: [64]u8 = undefined;
    const report: data.ReportEffect = .{
        .plan = .{
            .pane_id = @enumFromInt(1),
            .content = .{ .x = 2, .y = 3, .w = 10, .h = 5 },
            .protocol = .{ .tracking = .any, .sgr = true, .pixels = true },
            .alternate_scroll = false,
            .at_bottom = true,
        },
        .command = .{
            .event = .{
                .x = 2,
                .y = 3,
                .raw_x = 27,
                .raw_y = 69,
                .kind = .press,
            },
            .exterior_pixels = true,
            .cell_width_px = 10,
            .cell_height_px = 20,
        },
    };

    try std.testing.expectEqualStrings("\x1b[<0;8;10M", try encodeReport(&buffer, report));
}

test "pane mouse pixel reports use cell centers without exact host pixels" {
    var buffer: [64]u8 = undefined;
    const report: data.ReportEffect = .{
        .plan = .{
            .pane_id = @enumFromInt(1),
            .content = .{ .x = 2, .y = 3, .w = 10, .h = 5 },
            .protocol = .{ .tracking = .any, .sgr = true, .pixels = true },
            .alternate_scroll = false,
            .at_bottom = true,
        },
        .command = .{
            .event = .{ .x = 3, .y = 4, .kind = .press },
            .exterior_pixels = false,
            .cell_width_px = 10,
            .cell_height_px = 20,
        },
    };

    try std.testing.expectEqualStrings("\x1b[<0;16;31M", try encodeReport(&buffer, report));
}

/// Resolves a pointer event or focused scroll without exposing pane storage
/// or child mouse modes to the caller.
/// Example: `_ = try pane_mouse_input.inputPaneMouse(app, tab, command);`
pub fn inputPaneMouse(client: *Client, tab: usize, command: data.PaneMouseCommand) !data.PaneMouseOutcome {
    const area = client.geometry().area;
    const resolved: data.Resolved = switch (command) {
        .pointer => |pointer| .{
            .plan = data.tab_layout.planPaneMouse(&client.model, tab, pointer.event, area) orelse return .ignored,
            .pointer = pointer,
        },
        .focused_scroll => |direction| focused: {
            const plan = data.tab_layout.planFocusedPaneMouse(&client.model, tab, area) orelse return .ignored;
            const host_size = client.model.host.host_size;

            break :focused .{
                .plan = plan,
                .pointer = .{
                    .event = .{
                        .x = plan.content.x,
                        .y = plan.content.y,
                        .kind = if (direction == .up) .scroll_up else .scroll_down,
                        .button = if (direction == .up) 64 else 65,
                    },
                    .exterior_pixels = false,
                    .cell_width_px = host_size.cell_width_px,
                    .cell_height_px = host_size.cell_height_px,
                },
            };
        },
    };
    const plan = resolved.plan;
    const pointer = resolved.pointer;

    const forced_selection = pointer.event.button & 4 != 0;
    if (pointer.event.kind == .press and pointer.event.button & 0b11 == 0 and
        (plan.protocol.tracking == .none or forced_selection))
    {
        try applyPaneMouseEffect(
            client,
            .{
                .selection = .{
                    .plan = plan,
                    .command = pointer,
                },
            },
        );
        return .selection_started;
    }

    const wheel_delta: ?i32 = switch (pointer.event.kind) {
        .scroll_up => -3,
        .scroll_down => 3,
        else => null,
    };

    const tracked = plan.protocol.sgr and mouse_protocol_module.tracked(plan.protocol.tracking, pointer.event.kind);

    if (wheel_delta) |delta| {
        if (!tracked) {
            if (plan.alternate_scroll and plan.at_bottom) {
                try applyPaneMouseEffect(
                    client,
                    .{
                        .alternate_scroll = .{
                            .pane_id = plan.pane_id,
                            .delta = delta,
                        },
                    },
                );
                return .alternate_scroll_selected;
            }

            try applyPaneMouseEffect(
                client,
                .{
                    .viewport = .{
                        .pane_id = plan.pane_id,
                        .delta = delta,
                    },
                },
            );
            return .viewport_selected;
        }
    }

    if (!tracked) {
        return .ignored;
    }

    try applyPaneMouseEffect(
        client,
        .{
            .report = .{
                .plan = plan,
                .command = pointer,
            },
        },
    );
    return .report_selected;
}

/// Delivers a host-retained gesture to its original pane after the host has
/// checked attachment identity and projected its current rectangle.
/// Example: `try reportRetained(client, report);`
/// Example: `try pane_mouse_input.reportRetainedPaneMouse(app, report);`
pub fn reportRetainedPaneMouse(client: *Client, report: data.ReportEffect) !void {
    return deliverPaneMouseReport(client, report, true);
}

fn applyPaneMouseEffect(client: *Client, effect: data.PaneMouseEffect) !void {
    switch (effect) {
        .selection => |selection| {
            _ = client.model.beginPointerSelection(
                .{
                    .pane_id = selection.plan.pane_id,
                    .position = .{
                        .x = selection.command.event.x - selection.plan.content.x,
                        .y = selection.command.event.y - selection.plan.content.y,
                    },
                    .now_ns = pacing.clock.monotonic(client.io),
                },
            );
        },
        .viewport => |scroll| {
            _ = try pane_viewport.applyPaneViewport(
                client,
                .{
                    .pane_id = scroll.pane_id,
                    .target = .{
                        .relative = scroll.delta,
                    },
                },
            );
        },
        .alternate_scroll => |scroll| {
            std.debug.assert(scroll.delta != 0);
            const bytes = if (scroll.delta < 0) "\x1b[A" else "\x1b[B";
            for (0..@abs(scroll.delta)) |_| {
                _ = try pane_input.sendPaneInput(
                    client,
                    .{
                        .target = .{
                            .pane = scroll.pane_id,
                        },
                        .source = .mouse,
                        .payload = .{
                            .bytes = bytes,
                        },
                    },
                );
            }
        },
        .report => |report| {
            try deliverPaneMouseReport(client, report, false);
        },
    }
}

fn deliverPaneMouseReport(client: *Client, report: data.ReportEffect, retained: bool) !void {
    var encoded: [64]u8 = undefined;
    const bytes = try encodeReport(&encoded, report);
    _ = try pane_input.sendPaneInput(
        client,
        .{
            .target = if (retained) .{
                .pointer_lease = report.plan.pane_id,
            } else .{
                .pane = report.plan.pane_id,
            },
            .source = .mouse,
            .payload = .{
                .bytes = bytes,
            },
        },
    );
}
