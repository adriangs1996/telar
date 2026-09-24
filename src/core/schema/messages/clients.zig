const bytecodec = @import("bytecodec");
const std = @import("std");
const codec = @import("../codec.zig");
const tags = @import("tags.zig");
const id = @import("../id.zig");
const Encoder = bytecodec.Encoder;
const Decoder = bytecodec.Decoder;
const DetachClient = @import("DetachClient.zig");
const QueryClients = @import("QueryClients.zig");
const ClientList = @import("../../ClientList.zig");
const GenericDerived = @import("../GenericDerived.zig").Type;

/// Encodes a read-only UI discovery request. Example: `const bytes = try clients.encodeQueryClients(buffer, query);`
pub fn encodeQueryClients(buffer: []u8, query: QueryClients) ![]const u8 {
    return codec.encodeDerived(@intFromEnum(tags.ClientTag.query_clients), buffer, query);
}

/// Decodes the correlated query. Example: `const query = try clients.decodeQueryClients(decoder);`
pub fn decodeQueryClients(decoder: *Decoder) !QueryClients {
    return GenericDerived(QueryClients).decode(decoder);
}

/// Encodes only occupied catalog entries. Example: `const bytes = try clients.encodeClientList(buffer, list);`
pub fn encodeClientList(buffer: []u8, list: ClientList) ![]const u8 {
    try codec.validateRequestId(list.request_id);
    if (list.count > ClientList.capacity) {
        return error.InvalidClientList;
    }

    var encoder = Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ServerTag.client_list));
    try encoder.writeInt(u64, id.raw(list.request_id));
    try encoder.writeByte(list.count);
    for (list.entries[0..list.count]) |entry| {
        if (entry.id == 0 or entry.generation == 0 or entry.identity == 0) {
            return error.InvalidClientRoute;
        }

        try encoder.writeInt(u64, entry.id);
        try encoder.writeInt(u64, entry.generation);
        try encoder.writeInt(u64, entry.identity);
        try encoder.writeInt(u16, entry.attachments);
        try encoder.writeInt(u64, entry.last_input_pane);
        try encoder.writeInt(u64, entry.last_input_sequence);
    }

    return encoder.finish();
}

/// Owns a bounded decoded catalog. Example: `const list = try clients.decodeClientList(decoder);`
pub fn decodeClientList(decoder: *Decoder) !ClientList {
    var list: ClientList = .{ .request_id = try id.request(try decoder.readInt(u64)), .count = try decoder.readByte() };
    if (list.count > ClientList.capacity) {
        return error.InvalidClientList;
    }

    for (list.entries[0..list.count], 0..) |*entry, index| {
        entry.* = .{
            .id = try decoder.readInt(u64),
            .generation = try decoder.readInt(u64),
            .identity = try decoder.readInt(u64),
            .attachments = try decoder.readInt(u16),
            .last_input_pane = try decoder.readInt(u64),
            .last_input_sequence = try decoder.readInt(u64),
        };
        if (entry.id == 0 or entry.generation == 0 or entry.identity == 0) {
            return error.InvalidClientRoute;
        }

        for (list.entries[0..index]) |previous| {
            if (entry.id == previous.id) {
                return error.InvalidClientList;
            }
        }
    }

    return list;
}

test "client catalog refuses oversized counts and invalid routes" {
    var bytes: [128]u8 = undefined;
    var list: ClientList = .{ .request_id = @enumFromInt(1), .count = ClientList.capacity + 1 };
    try std.testing.expectError(error.InvalidClientList, encodeClientList(&bytes, list));
    list.count = 1;
    list.entries[0] = .{ .id = 0, .generation = 1, .identity = 2, .attachments = 0, .last_input_pane = 0, .last_input_sequence = 0 };
    try std.testing.expectError(error.InvalidClientRoute, encodeClientList(&bytes, list));
    list.entries[0].id = 3;
    const encoded = try encodeClientList(&bytes, list);
    var decoder = Decoder.init(encoded[1..]);
    const decoded = try decodeClientList(&decoder);
    try std.testing.expectEqualDeep(list.entries[0], decoded.entries[0]);
}

/// Requests teardown of one exact UI connection. Example: `const bytes = try clients.encodeDetachClient(buffer, request);`
pub fn encodeDetachClient(buffer: []u8, request: DetachClient) ![]const u8 {
    return codec.encodeDerived(@intFromEnum(tags.ClientTag.detach_client), buffer, request);
}

/// Decodes generation-scoped teardown. Example: `const request = try clients.decodeDetachClient(decoder);`
pub fn decodeDetachClient(decoder: *Decoder) !DetachClient {
    return GenericDerived(DetachClient).decode(decoder);
}
