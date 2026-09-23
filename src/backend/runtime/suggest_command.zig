//! A client asks for a command in words; the runtime's headless engine
//! answers one command line from the pane's cwd and screen.

const core = @import("telar-core");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const PendingSuggestion = @import("delivery/PendingSuggestion.zig");
const EngineResponse = @import("../engine/Response.zig");
const Prompt = @import("../engine/Prompt.zig");
const Sources = @import("Sources.zig");
const engine_types = @import("../engine/types.zig");
const suggestion = @import("application/suggestion.zig");

/// Submits one bounded prompt to the engine, or replies at once when the
/// engine is absent or saturated.
///
/// ```zig
/// try suggest_command.start(model, session, request);
/// ```
pub fn start(model: *RuntimeModel, session: *Session, request: core.SuggestCommand) !void {
    const service = model.resources.engineService() orelse {
        return reply(session, request.request_id, .unavailable);
    };
    const pane = model.panes.resolveControl(.{ .id = request.pane_id, .generation = 0 }) orelse {
        return reply(session, request.request_id, .failed);
    };

    var screen_storage: [core.max_pane_text_bytes]u8 = undefined;
    const dump = pane.dumpText(.{ .rows = suggestion.context_rows, .source = .screen }, &screen_storage);
    var prompt_buffer: [engine_types.max_prompt_bytes]u8 = undefined;
    const prompt = suggestion.buildPrompt(.{
        .cwd = pane.cwd.slice(),
        .screen = screen_storage[0..dump.len],
        .request = request.text,
    }, &prompt_buffer);
    const purpose: engine_types.Purpose = .{ .suggestion = .{
        .client_id = session.key.id,
        .client_generation = session.key.generation,
        .request_id = core.raw(request.request_id),
    } };
    const queued = Prompt.init(purpose, prompt) catch null;
    if (queued == null or !service.submit(model.io, .{ .prompt = queued.? })) {
        return reply(session, request.request_id, .failed);
    }
}

/// Takes one engine reply, rearms the engine receive and answers the
/// client that asked, if it is still connected.
///
/// ```zig
/// try suggest_command.finish(model, result);
/// ```
pub fn finish(model: *RuntimeModel, result: anyerror!EngineResponse) !void {
    const response = result catch return;
    const service = model.resources.engineService() orelse return;
    var sources = Sources.init(model.io, model.select);
    try sources.receiveEngine(service);

    switch (response.purpose) {
        .suggestion => |target| deliver(model, target, &response),
    }
}

/// Asks the engine to stop its child when it has been idle.
/// Example: `suggest_command.stopIdleEngine(model);`.
pub fn stopIdleEngine(model: *RuntimeModel) void {
    const service = model.resources.engineService() orelse return;
    service.requestIdleCheck(model.io);
}

fn deliver(model: *RuntimeModel, target: engine_types.Purpose.Suggestion, response: *const EngineResponse) void {
    const session = model.clients.resolve(.{ .id = target.client_id, .generation = target.client_generation }) orelse return;
    var pending: PendingSuggestion = .{
        .request_id = @enumFromInt(target.request_id),
        .status = switch (response.status) {
            .success => .ready,
            .unavailable => .unavailable,
            .timeout => .timeout,
            .invalid_output, .failed => .failed,
        },
    };

    if (pending.status == .ready) {
        if (suggestion.extractCommand(response.textSlice())) |command| {
            @memcpy(pending.text[0..command.len], command);
            pending.text_len = @intCast(command.len);
        } else {
            pending.status = .failed;
        }
    }

    session.delivery.responses.push(.{ .command_suggestion = pending }) catch return;
}

fn reply(session: *Session, request_id: core.RequestId, status: core.SuggestionStatus) !void {
    try session.delivery.responses.push(.{ .command_suggestion = .{ .request_id = request_id, .status = status } });
}
