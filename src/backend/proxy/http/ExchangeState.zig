const ExchangeState = @This();
const source_namespace = @import("connection.zig");
body_finished: bool = false,

pub fn accept(state: *ExchangeState, event: source_namespace.Event) ?source_namespace.ExchangeOutcome {
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
