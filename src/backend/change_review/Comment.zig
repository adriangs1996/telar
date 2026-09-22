const std = @import("std");
const core = @import("telar-core");
const Comment = @This();

id: u64 = 0,
path: [core.change_review.max_path_bytes]u8 = undefined,
path_len: u16 = 0,
first_line: u32 = 0,
last_line: u32 = 0,
side: core.change_review.Side = .after,
body: [core.change_review.max_comment_bytes]u8 = undefined,
body_len: u16 = 0,
draft: bool = false,

pub fn init(id: u64, command: core.ChangeReviewCommand) !Comment {
    if (command.path.len > core.change_review.max_path_bytes or command.body.len > core.change_review.max_comment_bytes or !std.unicode.utf8ValidateSlice(command.body) or !std.unicode.utf8ValidateSlice(command.path) or std.mem.indexOfScalar(u8, command.body, 0) != null or std.mem.indexOfScalar(u8, command.path, 0) != null) {
        return error.InvalidReviewComment;
    }
    var result: Comment = .{ .id = id, .path_len = @intCast(command.path.len), .body_len = @intCast(command.body.len), .first_line = command.first_line, .last_line = command.last_line, .side = command.side, .draft = command.draft };
    @memcpy(result.path[0..command.path.len], command.path);
    @memcpy(result.body[0..command.body.len], command.body);
    return result;
}

pub fn pathSlice(self: *const Comment) []const u8 {
    return self.path[0..self.path_len];
}

pub fn bodySlice(self: *const Comment) []const u8 {
    return self.body[0..self.body_len];
}

pub fn view(self: *const Comment) core.ChangeReviewComment {
    return .{ .id = self.id, .path = self.pathSlice(), .first_line = self.first_line, .last_line = self.last_line, .side = self.side, .body = self.bodySlice(), .draft = self.draft };
}
