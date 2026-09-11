//! HTTP negotiation required to observe Claude's streaming protocol.

const TransformerType = @import("../Transformer.zig");
const TransformationType = @import("../Transformation.zig");
const middleware = @import("../middleware.zig");
const request = @import("request_support.zig");
const HeaderViewType = @import("../HeaderView.zig");
const std = @import("std");
const TransformCase = @import("TransformCase.zig");
const EffectBatchType = @import("../EffectBatch.zig");

var stateless_context: u8 = 0;

/// Returns the header transformer that requests identity-encoded Claude SSE.
/// It changes only Claude `POST /v1/messages` request headers; auxiliary
/// routes, responses, and other providers are preserved.
///
/// ```zig
/// try pipeline.add(claude_transport.requestTransformer());
/// ```
pub fn requestTransformer() TransformerType {
    return .{ .context = &stateless_context, .transform = transform };
}

fn transform(_: *anyopaque, transformation: TransformationType) middleware.TransformStatus {
    const snapshot = transformation.snapshot;

    if (snapshot.context.dialect != .anthropic_messages or
        snapshot.context.direction != .request or
        snapshot.context.kind != .request)
    {
        return .preserve;
    }

    const method = uniqueHeader(snapshot.fields, ":method") orelse return .preserve;
    const target = uniqueHeader(snapshot.fields, ":path") orelse return .preserve;
    if (request.classify(.anthropic_messages, .{ .method = method, .target = target }) != .inference) {
        return .preserve;
    }

    transformation.effects.set(.{
        .name = "accept-encoding",
        .value = "identity",
    }) catch return .preserve;
    return .apply;
}

fn uniqueHeader(fields: []const HeaderViewType, wanted: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;

    for (fields) |field| {
        if (!std.ascii.eqlIgnoreCase(field.name, wanted)) {
            continue;
        }

        if (found != null) {
            return null;
        }

        found = field.value;
    }

    return found;
}

fn apply(case: TransformCase, effects: *EffectBatchType) middleware.TransformStatus {
    var fields: [3]HeaderViewType = undefined;
    fields[0] = .{ .name = ":method", .value = case.method };
    fields[1] = .{ .name = ":path", .value = case.target };
    var len: usize = 2;

    if (case.encoding) |encoding| {
        fields[len] = .{ .name = "accept-encoding", .value = encoding };
        len += 1;
    }

    return transform(&stateless_context, .{
        .io = std.testing.io,
        .snapshot = .{
            .context = .{
                .pane_id = @enumFromInt(1),
                .pane_generation = 1,
                .dialect = case.dialect,
                .protocol = .http11,
                .direction = case.direction,
                .kind = case.kind,
                .connection_id = 1,
                .stream_id = 0,
            },
            .fields = fields[0..len],
        },
        .effects = effects,
    });
}

fn expectIdentityEffect(effects: *const EffectBatchType) !void {
    try std.testing.expectEqual(@as(u8, 1), effects.len);

    switch (effects.effects[0]) {
        .set => |header| {
            try std.testing.expectEqualStrings("accept-encoding", header.name);
            try std.testing.expectEqualStrings("identity", header.value);
            try std.testing.expect(!header.sensitive);
        },
        .remove => return error.ExpectedSetEffect,
    }
}

test "Claude inference requests negotiate identity encoding" {
    inline for (.{
        TransformCase{},
        TransformCase{ .target = "/v1/messages?beta=true" },
        TransformCase{ .encoding = null },
    }) |case| {
        var effects: EffectBatchType = .{};

        try std.testing.expectEqual(middleware.TransformStatus.apply, apply(case, &effects));
        try expectIdentityEffect(&effects);
    }
}

test "Claude identity negotiation preserves unrelated traffic" {
    inline for (.{
        TransformCase{ .dialect = .openai_responses },
        TransformCase{ .direction = .response },
        TransformCase{ .kind = .trailers },
        TransformCase{ .method = "GET" },
        TransformCase{ .target = "/v1/messages/count_tokens" },
        TransformCase{ .target = "/api/event_logging/v2/batch" },
    }) |case| {
        var effects: EffectBatchType = .{};

        try std.testing.expectEqual(middleware.TransformStatus.preserve, apply(case, &effects));
        try std.testing.expectEqual(@as(u8, 0), effects.len);
    }
}

test "Claude identity negotiation rejects ambiguous pseudo headers" {
    const fields = [_]HeaderViewType{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":path", .value = "/v1/messages" },
        .{ .name = ":path", .value = "/v1/messages" },
    };
    var effects: EffectBatchType = .{};
    const status = transform(&stateless_context, .{
        .io = std.testing.io,
        .snapshot = .{
            .context = .{
                .pane_id = @enumFromInt(1),
                .pane_generation = 1,
                .dialect = .anthropic_messages,
                .protocol = .h2,
                .direction = .request,
                .kind = .request,
                .connection_id = 1,
                .stream_id = 1,
            },
            .fields = &fields,
        },
        .effects = &effects,
    });

    try std.testing.expectEqual(middleware.TransformStatus.preserve, status);
    try std.testing.expectEqual(@as(u8, 0), effects.len);
}
