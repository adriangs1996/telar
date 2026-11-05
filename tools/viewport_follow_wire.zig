//! Fixture-only C ABI. build_viewport_follow_wire.py places this beside the
//! exact reference revision schema; no wire layout is duplicated here.

const std = @import("std");
const bytecodec = @import("bytecodec");
const handshake = @import("schema/handshake.zig");
const pane = @import("schema/messages/pane.zig");
const runtime = @import("schema/messages/runtime.zig");
const frame = @import("schema/frame_support.zig");
const tags = @import("schema/messages/tags.zig");
const PaneOpened = @import("schema/messages/PaneOpened.zig");
const PaneExited = @import("schema/messages/PaneExited.zig");
const GenericDerived = @import("schema/GenericDerived.zig");
const id = @import("schema/id.zig");

const Operation = enum(u32) { hello, subscribe, open, viewport, input, acknowledge, close, read_pane };
const Request = extern struct {
    operation: u32,
    pane_id: u64,
    value: u64,
    text: [*:0]const u8,
    extra: [*:0]const u8,
};
const View = extern struct {
    pane_id: u64,
    generation: u64,
    frame_id: u64,
    base_frame_id: u64,
    total: u32,
    offset: u32,
    columns: u16,
    rows: u16,
};
const Event = enum(c_int) { failed = -1, ignored, accepted, opened, frame, exited, output_complete, output_pending };
const columns = 82;
const rows = 21;

fn encode(request: *const Request, output: []u8) ![]const u8 {
    const operation = std.enums.fromInt(Operation, request.operation) orelse return error.UnknownOperation;
    return switch (operation) {
        .hello => handshake.encodeClientHello(output, .{}),
        .subscribe => runtime.encodeRequestRuntimeState(output, .{
            .client_identity = @enumFromInt(request.value),
            .interactive = true,
        }),
        .open => pane.encodeOpenPane(output, .{
            .request_id = @enumFromInt(request.value),
            .size = .{
                .cols = columns,
                .rows = rows,
            },
            .launch = .{
                .cwd = "/tmp",
                .arguments = &.{
                    std.mem.span(request.text),
                    "--child",
                    std.mem.span(request.extra),
                },
            },
        }),
        .viewport => pane.encodeSetPaneViewport(output, .{
            .pane_id = @enumFromInt(request.pane_id),
            .offset = std.math.cast(u32, request.value) orelse return error.Overflow,
        }),
        .input => pane.encodePaneInput(output, .{
            .pane_id = @enumFromInt(request.pane_id),
            .bytes = std.mem.span(request.text),
        }),
        .acknowledge => pane.encodeFrameAck(output, .{
            .pane_id = @enumFromInt(request.pane_id),
            .frame_id = request.value,
        }),
        .read_pane => pane.encodeReadPane(output, .{
            .request_id = @enumFromInt(3),
            .pane_id = @enumFromInt(request.pane_id),
            .pane_generation = request.value,
            .rows = rows,
            .source = .screen,
        }),
        .close => pane.encodeClosePane(output, .{
            .pane_id = @enumFromInt(request.pane_id),
            .request_id = @enumFromInt(request.value),
        }),
    };
}

export fn viewport_encode(request: *const Request, output: [*]u8, capacity: usize) isize {
    const payload = encode(request, output[0..capacity]) catch return -1;
    return @intCast(payload.len);
}

fn apply(payload: []const u8, view: *View, cells: []u8) !Event {
    if (std.mem.startsWith(u8, payload, &handshake.magic)) {
        const response = try handshake.decodeServerResponse(payload);
        switch (response) {
            .accepted => |accepted| {
                if (!std.mem.eql(u8, &accepted.schema, &handshake.schema_id)) {
                    return error.WrongSchema;
                }
                return .accepted;
            },
            .rejected => return error.RejectedSchema,
        }
    }

    var decoder = bytecodec.Decoder.init(payload);
    const tag = try decoder.readByte();
    if (tag == @intFromEnum(tags.ServerTag.pane_opened)) {
        const opened = try GenericDerived.Type(PaneOpened).decode(&decoder);
        try decoder.ensureEnd();
        if (id.raw(opened.request_id) != 1 or view.pane_id != 0) {
            return error.WrongPaneOpen;
        }

        view.pane_id = id.raw(opened.pane_id);
        view.generation = opened.pane_generation;
        return .opened;
    }

    if (tag == @intFromEnum(tags.ServerTag.pane_exited)) {
        const exited = try GenericDerived.Type(PaneExited).decode(&decoder);
        try decoder.ensureEnd();
        if (id.raw(exited.pane_id) != view.pane_id or exited.value != 0) {
            return error.WrongChildExit;
        }
        return .exited;
    }

    if (tag == @intFromEnum(tags.ServerTag.pane_text)) {
        const text = try pane.decodePaneText(&decoder);
        try decoder.ensureEnd();
        if (id.raw(text.pane_id) != view.pane_id or id.raw(text.request_id) != 3) {
            return error.WrongPaneText;
        }
        return if (std.mem.indexOf(u8, text.text, "row000124") != null) .output_complete else .output_pending;
    }

    if (tag == @intFromEnum(tags.ServerTag.request_failed)) {
        return error.RequestFailed;
    }

    if (tag != @intFromEnum(tags.ServerTag.pane_frame)) {
        return .ignored;
    }

    const next = try frame.decodeBody(&decoder);
    try decoder.ensureEnd();

    if (id.raw(next.pane_id) != view.pane_id or next.frame_id <= view.frame_id or next.cols != columns or next.rows != rows or cells.len != columns * rows or (next.base_frame_id != 0 and next.base_frame_id != view.frame_id)) {
        return error.WrongFrame;
    }

    if (next.base_frame_id == 0) {
        @memset(cells, ' ');
    }

    var spans = next.spans();
    while (try spans.next()) |span| {
        var reader = span.cells();
        var index: usize = span.start;
        while (try reader.next()) |cell| {
            if (index >= cells.len or cell.width != 1 or cell.len != 1 or cell.bytes[0] < ' ' or cell.bytes[0] > '~') {
                return error.NonAsciiFixtureCell;
            }
            cells[index] = cell.bytes[0];
            index += 1;
        }
    }

    view.* = .{
        .pane_id = id.raw(next.pane_id),
        .generation = view.generation,
        .frame_id = next.frame_id,
        .base_frame_id = next.base_frame_id,
        .total = next.scroll.total_rows,
        .offset = next.scroll.offset,
        .columns = next.cols,
        .rows = next.rows,
    };
    return .frame;
}

export fn viewport_apply(input: [*]const u8, length: usize, view: *View, cells: [*]u8, capacity: usize) c_int {
    const event = apply(input[0..length], view, cells[0..capacity]) catch |err| {
        std.debug.print("viewport wire: {s}\n", .{
            @errorName(err),
        });
        return @intFromEnum(Event.failed);
    };

    return @intFromEnum(event);
}
