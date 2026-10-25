const std = @import("std");
const core = @import("telar-core");

export fn plugin_data(mode: c_uint, input: [*]const u8, length: usize, output: [*]u8, capacity: usize) usize {
    return run(mode, input[0..length], output[0..capacity]) catch 0;
}

fn run(mode: c_uint, source: []const u8, output: []u8) !usize {
    var writer: std.Io.Writer = .fixed(output);
    const memory = std.heap.page_allocator;
    if (mode == 0) {
        const manifest = try core.parseManifest(memory, source);
        try writeText(&writer, manifest.id());
        try writeText(&writer, manifest.version());
        try writeText(&writer, manifest.entry());
        try writeText(&writer, manifest.source());
        try writeText(&writer, manifest.revision());
        try writer.writeByte(manifest.action_count);
        for (manifest.actions[0..manifest.action_count]) |action| {
            try writeText(&writer, action.slice());
        }
        try writeCapabilities(&writer, manifest.capabilities);
    } else {
        const trust = try core.TrustStore.parse(memory, source);
        try writer.writeByte(trust.count);
        for (trust.entries[0..trust.count]) |entry| {
            try writeText(&writer, entry.pluginId());
            try writeText(&writer, &entry.grant.digest);
            try writeCapabilities(&writer, entry.grant.capabilities);
        }
    }
    return writer.buffered().len;
}

fn writeText(writer: *std.Io.Writer, text: []const u8) !void {
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(text.len), .little);
    try writer.writeAll(&length);
    try writer.writeAll(text);
}

fn writeCapabilities(writer: *std.Io.Writer, capabilities: core.CapabilitySet) !void {
    inline for (std.meta.fields(core.Capability)) |field| {
        try writer.writeByte(@intFromBool(capabilities.contains(@enumFromInt(field.value))));
    }
}
