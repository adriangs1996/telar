const jsonl = @import("jsonl");
const std = @import("std");
const ItemUpdate = @import("ItemUpdate.zig");
const ItemNormalizer = @import("ItemNormalizer.zig");

/// Retains known items and renders unsupported activity as bounded JSON.
/// Returned slices borrow the caller's normalizer until appended to the page.
/// Example: `const item = try historical_item.normalize(&normalizer, value);`
pub fn normalize(normalizer: *ItemNormalizer, item: std.json.Value) !ItemUpdate {
    if (normalizer.item(item, true)) |update| {
        return update;
    }

    if (jsonl.is(jsonl.field(item, "type"), "subAgentActivity")) {
        const kind = jsonl.field(item, "kind");
        return .{
            .id = jsonl.string(jsonl.field(item, "id")),
            .role = .tool,
            .kind = .subagent,
            .title = std.fs.path.basename(jsonl.string(jsonl.field(item, "agentPath"))),
            .detail = jsonl.string(kind),
            .reference = jsonl.string(jsonl.field(item, "agentThreadId")),
            .status = if (jsonl.is(kind, "completed")) .idle else if (jsonl.is(kind, "interrupted")) .interrupted else .completed,
            .complete = true,
        };
    }

    var writer: std.Io.Writer = .fixed(normalizer.body_buffer orelse &normalizer.body);
    std.json.Stringify.value(item, .{}, &writer) catch return error.HistoryItemNotRepresentable;
    return .{
        .id = jsonl.string(jsonl.field(item, "id")),
        .role = .system,
        .kind = .system,
        .title = "Codex activity",
        .detail = jsonl.string(jsonl.field(item, "type")),
        .text = writer.buffered(),
        .complete = true,
    };
}
