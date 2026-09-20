const std = @import("std");
const core = @import("telar-core");
const Cursor = @import("Cursor.zig");
const entity_target = @import("entity_target.zig");
const SuggestionOptions = @This();

target: entity_target.Target,
text: []const u8,
json: bool = false,
socket: ?[*:0]const u8 = null,

/// Parses a bounded suggestion without executing it. Example: `try SuggestionOptions.parse(&.{ "suggest", "7", "List files" });`
pub fn parse(args: []const [*:0]const u8) !SuggestionOptions {
    if (args.len < 3 or !std.mem.eql(u8, std.mem.span(args[0]), "suggest")) {
        return error.InvalidSuggestionCommand;
    }

    var self: SuggestionOptions = .{ .target = try entity_target.Target.parse(std.mem.span(args[1])), .text = std.mem.span(args[2]) };
    if (self.text.len == 0 or self.text.len > core.max_suggestion_request_bytes or !std.unicode.utf8ValidateSlice(self.text)) {
        return error.InvalidSuggestionText;
    }

    var cursor: Cursor = .{ .remaining = args[3..] };
    while (cursor.next()) |argument| {
        const arg = std.mem.span(argument);
        if (std.mem.eql(u8, arg, "--json") and !self.json) {
            self.json = true;
        } else if (std.mem.eql(u8, arg, "--socket") and self.socket == null) {
            self.socket = try cursor.require(error.MissingSocketPath);
        } else {
            return error.UnknownSuggestionOption;
        }
    }

    return self;
}
