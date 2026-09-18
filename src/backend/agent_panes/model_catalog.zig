const std = @import("std");
const core = @import("telar-core");
const protocol = @import("protocol.zig");

/// Copies provider metadata and returns its default model index, or the first available entry when none is marked. Example: `const default_model = try model_catalog.load(snapshot, result);`
pub fn load(snapshot: *core.AgentThreadSnapshot, result: std.json.Value) !u8 {
    const data = protocol.field(result, "data");
    if (data != .array or data.array.items.len == 0 or data.array.items.len > core.agent_thread.max_models) {
        return error.InvalidProviderModelCatalog;
    }

    snapshot.model_count = 0;
    var default_model: ?u8 = null;
    for (data.array.items) |entry| {
        var model: core.AgentModel = .{};
        const id = protocol.string(protocol.field(entry, "model"));
        const label = protocol.string(protocol.field(entry, "displayName"));
        if (!validString(id, model.id.len) or !validString(label, model.label.len) or snapshot.findModel(id) != null) {
            return error.InvalidProviderModelCatalog;
        }

        @memcpy(model.id[0..id.len], id);
        model.id_len = @intCast(id.len);
        @memcpy(model.label[0..label.len], label);
        model.label_len = @intCast(label.len);
        const efforts = protocol.field(entry, "supportedReasoningEfforts");
        if (efforts != .array or efforts.array.items.len == 0 or efforts.array.items.len > model.effort_storage.len) {
            return error.InvalidProviderModelCatalog;
        }

        for (efforts.array.items) |supported| {
            const effort = try core.AgentEffort.init(protocol.string(protocol.field(supported, "reasoningEffort")));
            if (model.supports(effort)) {
                return error.InvalidProviderModelCatalog;
            }

            model.effort_storage[model.effort_count] = effort;
            model.effort_count += 1;
        }

        model.default_effort = try core.AgentEffort.init(protocol.string(protocol.field(entry, "defaultReasoningEffort")));
        if (!model.supports(model.default_effort)) {
            return error.InvalidProviderModelCatalog;
        }

        const is_default = protocol.field(entry, "isDefault");
        if (is_default == .bool and is_default.bool) {
            if (default_model != null) {
                return error.InvalidProviderModelCatalog;
            }

            default_model = snapshot.model_count;
        } else if (is_default != .null and is_default != .bool) {
            return error.InvalidProviderModelCatalog;
        }

        snapshot.model_storage[snapshot.model_count] = model;
        snapshot.model_count += 1;
    }

    return default_model orelse 0;
}

fn validString(value: []const u8, limit: usize) bool {
    return value.len > 0 and value.len <= limit and std.unicode.utf8ValidateSlice(value) and std.mem.indexOfScalar(u8, value, 0) == null;
}
