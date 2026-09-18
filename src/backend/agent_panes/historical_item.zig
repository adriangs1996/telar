const std = @import("std");
const protocol = @import("protocol.zig");
const ItemUpdate = @import("ItemUpdate.zig");
const ItemNormalizer = @import("ItemNormalizer.zig");

/// Retains known items and renders unsupported activity as bounded JSON.
/// Returned slices borrow the caller's normalizer until appended to the page.
/// Example: `const item = try historical_item.normalize(&normalizer, value);`
pub fn normalize(normalizer: *ItemNormalizer, item: std.json.Value) !ItemUpdate {
    if (normalizer.item(item, true)) |update| {
        return update;
    }

    if (protocol.is(protocol.field(item, "type"), "subAgentActivity")) {
        const kind = protocol.field(item, "kind");
        return .{
            .id = protocol.string(protocol.field(item, "id")),
            .role = .tool,
            .kind = .subagent,
            .title = std.fs.path.basename(protocol.string(protocol.field(item, "agentPath"))),
            .detail = protocol.string(kind),
            .reference = protocol.string(protocol.field(item, "agentThreadId")),
            .status = if (protocol.is(kind, "completed")) .idle else if (protocol.is(kind, "interrupted")) .interrupted else .completed,
            .complete = true,
        };
    }

    var writer: std.Io.Writer = .fixed(normalizer.body_buffer orelse &normalizer.body);
    std.json.Stringify.value(item, .{}, &writer) catch return error.HistoryItemNotRepresentable;
    return .{
        .id = protocol.string(protocol.field(item, "id")),
        .role = .system,
        .kind = .system,
        .title = "Codex activity",
        .detail = protocol.string(protocol.field(item, "type")),
        .text = writer.buffered(),
        .complete = true,
    };
}
