const connection = @import("connection.zig");
const ExchangeState = @This();

body_finished: bool = false,

pub fn accept(self: *ExchangeState, event: connection.Event) ?connection.ExchangeOutcome {
    return switch (event) {
        .request_body => |forwarded| block: {
            if (!forwarded) {
                break :block .failed;
            }

            self.body_finished = true;
            break :block null;
        },
        .response => |candidate| block: {
            const final = candidate orelse break :block .failed;

            break :block if (self.body_finished)
                .{ .complete = final }
            else
                .{ .early_response = final };
        },
    };
}
