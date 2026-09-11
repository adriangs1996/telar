const connection = @import("connection.zig");
const ExchangeState = @This();

body_finished: bool = false,

pub fn accept(state: *ExchangeState, event: connection.Event) ?connection.ExchangeOutcome {
    return switch (event) {
        .request_body => |forwarded| block: {
            if (!forwarded) {
                break :block .failed;
            }

            state.body_finished = true;
            break :block null;
        },
        .response => |candidate| block: {
            const final = candidate orelse break :block .failed;

            break :block if (state.body_finished)
                .{ .complete = final }
            else
                .{ .early_response = final };
        },
    };
}
