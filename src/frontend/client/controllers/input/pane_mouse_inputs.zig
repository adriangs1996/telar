//! Wires pane mouse policy to viewport and pane-input effects.

const std = @import("std");
const core = @import("telar-core");
const input_capability = @import("../../../input/root.zig");
const workspace_capability = @import("../../../workspace/root.zig");
const input_application = @import("telar-client").application.input;
const pane_inputs = @import("pane_inputs.zig");
const copy_modes = @import("copy_modes.zig");
const clock = @import("telar-client").resources.clock;
const pane_viewports = @import("../panes/pane_viewports.zig");

const Client = @import("../../Client.zig");
const mouse_protocol = input_capability.mouse_protocol;
pub const multiplexer = workspace_capability.multiplexer;
const pane_mouse = input_application.pane_mouse;
pub const ui = core.ui;

pub const Command = pane_mouse.Command;
pub const Outcome = pane_mouse.Outcome;

const Context = @import("PaneMouseInputsContext.zig");

/// Resolves a pointer event or focused scroll without exposing pane storage
/// or child mouse modes to the caller.
///
/// ```zig
/// _ = try apply(client, model, command);
/// ```
pub fn apply(client: *Client, model: *multiplexer.Model, command: Command) !Outcome {
    var context: Context = .{
        .client = client,
        .model = model,
        .area = client.geometry().area,
    };
    var use_case: pane_mouse.PaneMouseHandler = .{
        .plans = .{
            .context = &context,
            .resolve = resolve,
        },
        .effects = .{
            .context = &context,
            .apply = applyEffect,
        },
    };

    return use_case.execute(command);
}

fn resolve(raw_context: *anyopaque, command: Command) ?pane_mouse.Resolved {
    const context: *Context = @ptrCast(@alignCast(raw_context));

    return switch (command) {
        .pointer => |pointer| .{
            .plan = context.model.planPaneMouse(pointer.event, context.area) orelse return null,
            .pointer = pointer,
        },
        .focused_scroll => |direction| focused: {
            const plan = context.model.planFocusedPaneMouse(context.area) orelse return null;
            const host_size = context.client.model.hostSize();

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
}

fn applyEffect(raw_context: *anyopaque, effect: pane_mouse.Effect) !void {
    const context: *Context = @ptrCast(@alignCast(raw_context));

    switch (effect) {
        .selection => |selection| {
            _ = copy_modes.beginPointer(context.client, .{
                .pane_id = selection.plan.pane_id,
                .position = .{
                    .x = selection.command.event.x - selection.plan.content.x,
                    .y = selection.command.event.y - selection.plan.content.y,
                },
                .now_ns = clock.monotonic(context.client.io),
            });
        },
        .viewport => |scroll| {
            var use_case = pane_viewports.handler(context.client);

            _ = try use_case.execute(.{
                .pane_id = scroll.pane_id,
                .target = .{ .relative = scroll.delta },
            });
        },
        .alternate_scroll => |scroll| {
            std.debug.assert(scroll.delta != 0);
            const bytes = if (scroll.delta < 0) "\x1b[A" else "\x1b[B";
            for (0..@abs(scroll.delta)) |_| {
                _ = try pane_inputs.send(context.client, .{
                    .target = .{ .pane = scroll.pane_id },
                    .source = .mouse,
                    .payload = .{ .bytes = bytes },
                });
            }
        },
        .report => |report| {
            var encoded: [64]u8 = undefined;
            const bytes = try encodeReport(&encoded, report);

            _ = try pane_inputs.send(context.client, .{
                .target = .{ .pane = report.plan.pane_id },
                .source = .mouse,
                .payload = .{ .bytes = bytes },
            });
        },
    }
}

fn encodeReport(buffer: []u8, report: pane_mouse.ReportEffect) ![]const u8 {
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

    const pixels: ?mouse_protocol.PixelProjection = if (plan.protocol.pixels) .{
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
    const report: pane_mouse.ReportEffect = .{
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
    const report: pane_mouse.ReportEffect = .{
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
