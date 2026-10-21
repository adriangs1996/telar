const std = @import("std");
const backend = @import("telar-backend");
const privatefile = @import("privatefile");
const ServerOptions = @import("arguments/ServerOptions.zig");

const Origin = struct {
    version: u8 = 1,
    source_socket: []const u8,
    workspaces: []const []const u8,
};

/// Seeds an unused runtime directory once. A completed clone survives subsequent starts unchanged.
pub fn prepare(init: std.process.Init, options: ServerOptions, destination: []const u8, socket: []const u8) !void {
    const source_path = std.mem.span(options.clone_session orelse return);
    const source_socket = std.mem.span(options.clone_from.?);
    if (!std.fs.path.isAbsolute(source_path) or !std.fs.path.isAbsolute(source_socket) or !std.fs.path.isAbsolute(destination)) {
        return error.CloneRequiresAbsolutePaths;
    }
    if (std.mem.eql(u8, source_socket, socket) or std.mem.eql(u8, source_path, destination)) {
        return error.CannotCloneRuntimeOntoItself;
    }

    const io = init.io;
    const gpa = init.gpa;
    const held = try privatefile.lock(io, destination);
    defer held.close(io);
    var origin_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const origin_path = try std.fmt.bufPrint(&origin_buffer, "{s}.desktop-clone.json", .{socket});
    const previous = try privatefile.read(io, gpa, destination, .limited(backend.checkpoint.max_file_bytes));
    defer if (previous) |bytes| gpa.free(bytes);

    if (previous != null) {
        const bytes = try privatefile.read(io, gpa, origin_path, .limited(backend.checkpoint.max_file_bytes)) orelse return error.CloneDestinationAlreadyExists;
        defer gpa.free(bytes);
        const origin = try std.json.parseFromSlice(Origin, gpa, bytes, .{});
        defer origin.deinit();
        if (origin.value.version != 1 or !std.mem.eql(u8, origin.value.source_socket, source_socket)) {
            return error.CloneDestinationHasDifferentOrigin;
        }

        return;
    }

    const source = try privatefile.read(io, gpa, source_path, .limited(backend.checkpoint.max_file_bytes)) orelse return error.CloneSourceCheckpointMissing;
    defer gpa.free(source);
    const output = try gpa.alloc(u8, backend.checkpoint.max_file_bytes);
    defer gpa.free(output);
    const shell = init.minimal.environ.getPosix("SHELL") orelse "/bin/sh";
    const copied = try backend.clone_session.encode(source, output, shell);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    var workspaces: std.ArrayList([]const u8) = .empty;
    var reader = try backend.CheckpointReader.init(copied);
    while (try reader.next()) |record| {
        if (record == .workspace) {
            try workspaces.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{record.workspace.id}));
        }
    }

    const manifest = try std.json.Stringify.valueAlloc(allocator, Origin{
        .source_socket = source_socket,
        .workspaces = workspaces.items,
    }, .{});
    // The checkpoint is the commit marker. An interrupted first seed can safely write both again.
    try privatefile.replace(io, origin_path, manifest);
    try privatefile.replace(io, destination, copied);
}
