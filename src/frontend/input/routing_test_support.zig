//! Test-only collectors for typed router decisions. Never imported by a host.
const builtin = @import("builtin");
const Control = @import("telar-client").Control;

comptime {
    if (!builtin.is_test) {
        @compileError("router collectors are test-only");
    }
}

pub fn routeEvent(router: anytype, input: @TypeOf(router.*).KeyInput, capture: anytype) !Control {
    errdefer router.eventFailed(input.key);
    return apply(router, router.routeEvent(input, .{
        .captures_keys = if (@hasDecl(@TypeOf(capture.*), "capturesKeys")) capture.capturesKeys() else false,
        .repeat_policy = if (@hasDecl(@TypeOf(capture.*), "repeatPolicy")) if (router.repeatAction()) |held| capture.repeatPolicy(held) else null else null,
    }), capture);
}

pub fn apply(router: anytype, decision: @TypeOf(router.*).Decision, capture: anytype) !Control {
    switch (decision) {
        .forward => |value| {
            if (@hasDecl(@TypeOf(capture.*), "key")) {
                try capture.key(value.key);
            } else {
                try capture.forward(value.raw);
            }
        },
        .replay => |value| {
            if (@hasDecl(@TypeOf(capture.*), "key")) {
                for (value.held_keys[0..value.held_key_len]) |held| {
                    try capture.key(held);
                }
                if (value.current_key) |current| {
                    try capture.key(current);
                }
            } else {
                try capture.forward(value.held_raw[0..value.held_raw_len]);
                try capture.forward(value.current_raw);
            }
        },
        .action => |request| {
            const control = try capture.action(request.value);
            if (control == .continue_routing) {
                router.actionCompleted(request, if (@hasDecl(@TypeOf(capture.*), "repeatPolicy")) capture.repeatPolicy(request.value) else null);
            }
            return control;
        },
        .discard, .pending => {},
    }
    return .continue_routing;
}

pub fn feed(router: anytype, input: @TypeOf(router.*).Feed, capture: anytype) !Control {
    var remaining = input;
    while (router.next(&remaining)) |event| {
        if (try decoded(router, .{ .event = event, .now_ns = input.now_ns }, capture) == .stop) {
            router.clear();
            return .stop;
        }
    }
    return .continue_routing;
}

pub fn expireInput(router: anytype, now_ns: u64, capture: anytype) !Control {
    const event = router.expireInput(now_ns) orelse return .continue_routing;
    return decoded(router, .{ .event = event, .now_ns = now_ns }, capture);
}

pub fn expireBinding(router: anytype, now_ns: u64, capture: anytype) !Control {
    return apply(router, router.expireBinding(now_ns), capture);
}

fn decoded(router: anytype, input: anytype, capture: anytype) !Control {
    const event = input.event;
    if (event.paste_content) {
        if (@hasDecl(@TypeOf(capture.*), "pasteContent")) {
            try capture.pasteContent(event.raw);
        } else {
            try capture.forward(event.raw);
        }
        return .continue_routing;
    }
    switch (event.event) {
        .key => |key| return routeEvent(router, .{ .key = key, .raw = event.raw, .now_ns = input.now_ns }, capture),
        .mouse => |mouse| {
            if (@hasDecl(@TypeOf(capture.*), "mouse")) {
                router.cancelSequence();
                try capture.mouse(mouse);
            } else {
                _ = try apply(router, router.interrupt(), capture);
                try capture.forward(event.raw);
            }
        },
        .terminal_response => |response| {
            router.observeHostResponse();
            if (@hasDecl(@TypeOf(capture.*), "terminalResponse")) {
                try capture.terminalResponse(response);
            }
        },
        .paste_start => {
            _ = try apply(router, router.interrupt(), capture);
            if (@hasDecl(@TypeOf(capture.*), "pasteStart")) {
                try capture.pasteStart();
            } else {
                try capture.forward(event.raw);
            }
        },
        .paste_end => {
            _ = try apply(router, router.interrupt(), capture);
            if (@hasDecl(@TypeOf(capture.*), "pasteEnd")) {
                try capture.pasteEnd();
            } else {
                try capture.forward(event.raw);
            }
        },
        .incomplete => {
            _ = try apply(router, router.interrupt(), capture);
            if (!@hasDecl(@TypeOf(capture.*), "key")) {
                try capture.forward(event.raw);
            }
        },
    }
    return .continue_routing;
}
