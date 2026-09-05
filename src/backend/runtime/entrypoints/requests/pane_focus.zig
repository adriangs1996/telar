//! Protocol controller for one UI-directed pane-focus exchange.

const std = @import("std");
const core = @import("telar-core");
const panes = @import("../../../pane/root.zig");
const clients = @import("../../client/root.zig");
const telemetry = @import("../../observability/root.zig").telemetry;
const schema = core.schema;
const pane_mod = panes;
const ClientSession = clients.session.Session;
const ClientKey = clients.session.Key;

pub const Controller = struct {
    panes: *panes.PaneStore,
    clients: *clients.store.Store,
    metrics: *telemetry.RuntimeMetrics,
    input_sequence: *u64,
    delivery: struct {
        context: *anyopaque,
        pump: *const fn (*anyopaque, *ClientSession) anyerror!void,
    },

    fn pump(controller: *Controller, session: *ClientSession) !void {
        try controller.delivery.pump(controller.delivery.context, session);
    }

    /// Routes a control request to the UI that last supplied pane input.
    /// Example: `try controller.requestFocus(session, request);`.
    pub fn requestFocus(controller: *Controller, session: *ClientSession, focus: schema.RequestPaneFocus) !void {
        if (session.role != .control) {
            return error.InvalidClientRole;
        }

        const application = controller;
        const source_key: pane_mod.PaneKey = .{
            .id = focus.pane_id,
            .generation = focus.pane_generation,
        };
        const pane = application.panes.resolve(source_key) orelse {
            try session.delivery.responses.push(.{ .request_failed = .{
                .request_id = focus.request_id,
                .code = .pane_not_found,
                .message = "pane not found or its generation is stale",
            } });
            session.delivery.close_after_reply = true;
            return;
        };
        if (pane.exit != null) {
            try session.delivery.responses.push(.{ .request_failed = .{
                .request_id = focus.request_id,
                .code = .pane_exited,
                .message = "pane already exited",
            } });
            session.delivery.close_after_reply = true;
            return;
        }
        if (session.pending_pane_focus != null) {
            try session.delivery.responses.push(.{ .request_failed = .{
                .request_id = focus.request_id,
                .code = .invalid_request,
                .message = "one pane focus request is already pending",
            } });
            session.delivery.close_after_reply = true;
            return;
        }

        const target = paneFocusOrigin(application, source_key) orelse {
            try session.delivery.responses.push(.{ .request_failed = .{
                .request_id = focus.request_id,
                .code = .invalid_request,
                .message = "no active UI client originated input for this pane",
            } });
            session.delivery.close_after_reply = true;
            return;
        };
        try session.reserveFocus(.{
            .request_id = focus.request_id,
            .pane_id = focus.pane_id,
            .pane_generation = focus.pane_generation,
            .target = target.key,
        });
        target.delivery.responses.push(.{ .pane_focus_command = .{
            .requester = .{ .id = session.key.id, .generation = session.key.generation },
            .request_id = focus.request_id,
            .pane_id = focus.pane_id,
            .pane_generation = focus.pane_generation,
            .direction = focus.direction,
        } }) catch |err| {
            session.releaseFocus();
            return err;
        };
        try application.pump(target);
    }

    /// Accepts only the exact pending exchange from its chosen UI generation.
    /// Example: `try controller.completeFocus(session, reply);`.
    pub fn completeFocus(controller: *Controller, session: *ClientSession, completion: schema.CompletePaneFocus) !void {
        if (session.role != .ui) {
            return error.InvalidClientRole;
        }

        const requester_key: ClientKey = .{
            .id = completion.requester.id,
            .generation = completion.requester.generation,
        };
        const requester = controller.clients.resolve(requester_key) orelse return;
        if (requester.pending_pane_focus == null) {
            return;
        }

        if (requester.role != .control or !requester.acceptsFocusCompletion(session.key, completion)) {
            controller.metrics.stale_client_messages += 1;
            return;
        }

        try requester.delivery.responses.push(.{ .pane_focus_result = .{
            .request_id = completion.request_id,
            .outcome = completion.outcome,
            .focused_pane_id = completion.focused_pane_id,
        } });
        requester.releaseFocus();
        requester.delivery.close_after_reply = true;
        try controller.pump(requester);
    }

    /// Records input ordering used to resolve a future focus request.
    /// Example: `controller.notePaneInput(session, pane_id);`.
    pub fn notePaneInput(application: *Controller, session: *ClientSession, pane_id: schema.PaneId) void {
        application.input_sequence.* +%= 1;
        if (application.input_sequence.* == 0) {
            for (&application.clients.items) |*slot| {
                const client = slot.* orelse continue;
                client.last_input_sequence = 0;
            }
            application.input_sequence.* = 1;
        }

        session.last_input_pane = pane_id;
        session.last_input_sequence = application.input_sequence.*;
    }

    fn paneFocusOrigin(application: *Controller, pane_key: pane_mod.PaneKey) ?*ClientSession {
        var found: ?*ClientSession = null;
        var sequence: u64 = 0;
        for (&application.clients.items) |*slot| {
            const client = slot.* orelse continue;
            if (!client.active() or client.role != .ui or client.last_input_pane != pane_key.id or
                client.last_input_sequence <= sequence)
            {
                continue;
            }

            const attachment = client.attachments.find(pane_key.id) orelse continue;
            if (!std.meta.eql(attachment.pane.key(), pane_key)) {
                continue;
            }

            found = client;
            sequence = client.last_input_sequence;
        }
        return found;
    }
};
