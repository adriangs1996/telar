//! In-process inbox experiment, not the runtime's IPC implementation.
//! Periodic frame opportunities and unit replies deliberately remain simulation-only.

const std = @import("std");
const frontend = @import("telar-frontend");
const widgets = @import("exper_widgets.zig");

const Renderer = @import("exper/Renderer.zig");

const TerminalRenderer = @import("exper/TerminalRenderer.zig");
const GenericInbox = @import("src/core/interfaces/GenericInbox.zig").Type;
const GenericInboxReceiver = @import("src/core/interfaces/GenericInboxReceiver.zig").Type;

pub fn QueueInbox(comptime Message: type) type {
    return struct {
        const Self = @This();
        const Sender = GenericInbox(Message);
        const Consumer = GenericInboxReceiver(Message);

        queue: *std.Io.Queue(Message),
        io: std.Io,

        /// Borrows this adapter for publication. Keep it at a stable address.
        /// Queue admission copies Message by value, not any pointed-to payloads.
        /// Example: var sender = adapter.inbox();
        pub fn inbox(self: *Self) Sender {
            return .{
                .context = self,
                .post_fn = post,
            };
        }

        /// Borrows the same adapter for the sole consumer, without lifecycle access.
        /// Example: var receiver = adapter.inboxReceiver();
        pub fn inboxReceiver(self: *Self) Consumer {
            return .{
                .context = self,
                .pull_fn = pull,
            };
        }

        fn pull(context: *anyopaque) Consumer.Error!Message {
            const self: *Self = @ptrCast(@alignCast(context));

            return self.queue.getOne(self.io);
        }

        fn post(context: *anyopaque, msg: Message) Sender.Result {
            const self: *Self = @ptrCast(@alignCast(context));
            const count = self.queue.putUncancelable(self.io, &.{msg}, 0) catch {
                return .closed;
            };

            return if (count == 1) .accepted else .full;
        }
    };
}

pub const CounterView = struct {
    value: i32 = 0,

    pub fn increase(self: *CounterView) void {
        self.value += 1;
    }

    pub fn decrease(self: *CounterView) void {
        self.value -= 1;
    }
};

pub const FrontendContext = struct {
    backend_sink: *GenericInbox(BackendMessage),

    /// Admits a backend request without performing I/O or waiting for space.
    /// Example: try context.requestBackend(.{ .decide_operation_for = 3 });
    pub fn requestBackend(self: FrontendContext, msg: BackendMessage) !void {
        try postRequired(BackendMessage, self.backend_sink, msg);
    }
};

pub const Model = struct {
    counter: CounterView,

    /// Applies one client message; requests leave through the publication handle.
    /// Example: try model.update(.{ .request_operation = 3 }, context);
    pub fn update(self: *Model, msg: ClientMessage, ctx: FrontendContext) !void {
        switch (msg) {
            .request_operation => |amount| try ctx.requestBackend(.{ .decide_operation_for = amount }),
            .increase => self.counter.increase(),
            .decrease => self.counter.decrease(),
            .render, .quit => {},
        }
    }
};

pub const ScriptProducer = struct {
    io: std.Io,
    client_sink: *GenericInbox(ClientMessage),
    amounts: []const i32,
    interval_ms: u32 = 500,

    /// Sends the script once, pausing between requests.
    /// Example: try producer.run();
    pub fn run(self: ScriptProducer) !void {
        for (self.amounts, 0..) |amount, index| {
            if (index != 0) {
                try self.io.sleep(.fromMilliseconds(self.interval_ms), .awake);
            }

            try postRequired(ClientMessage, self.client_sink, .{ .request_operation = amount });
        }
    }
};

pub const FrameTicker = struct {
    io: std.Io,
    client_sink: *GenericInbox(ClientMessage),
    interval_ms: u32 = 16,

    /// Skips frame opportunities on saturation and stops when publication closes.
    /// Example: try ticker.run();
    pub fn run(self: FrameTicker) !void {
        while (true) {
            try self.io.sleep(.fromMilliseconds(self.interval_ms), .awake);

            switch (self.client_sink.post(.render)) {
                .accepted, .full => {},
                .closed => return,
            }
        }
    }
};

pub const BackendLoop = struct {
    receiver: *GenericInboxReceiver(BackendMessage),
    backend: Backend,

    /// Consumes requests until closure; errors and cancellation reach the owner.
    /// Example: try backend_loop.run();
    pub fn run(self: BackendLoop) !void {
        while (true) {
            const message = self.receiver.pull() catch |err| switch (err) {
                error.Closed => return,
                error.Canceled => return err,
            };

            switch (message) {
                .decide_operation_for => |amount| try self.backend.decideOperationFor(amount),
            }
        }
    }
};

pub const ClientLoop = struct {
    receiver: *GenericInboxReceiver(ClientMessage),
    model: *Model,
    context: FrontendContext,
    renderer: ?*Renderer = null,

    /// Owns every model update and render read until the inbox closes.
    /// Example: try client_loop.run();
    pub fn run(self: ClientLoop) !void {
        while (true) {
            const message = self.receiver.pull() catch |err| switch (err) {
                error.Closed => return,
                error.Canceled => return err,
            };

            if (message == .quit) {
                return;
            }

            try self.handle(message);
        }
    }

    fn handle(self: ClientLoop, message: ClientMessage) !void {
        switch (message) {
            .render => if (self.renderer) |renderer| try renderer.render(self.model.counter.value),
            else => try self.model.update(message, self.context),
        }
    }
};

pub const ClientMessage = union(enum) {
    request_operation: i32,
    increase,
    decrease,
    render,
    quit,
};

pub const Backend = struct {
    io: std.Io,
    client_sink: *GenericInbox(ClientMessage),

    /// Publishes unit replies, failing explicitly if a reply cannot be admitted.
    /// Replies already accepted are not rolled back on failure.
    /// Example: try backend.decideOperationFor(-2);
    pub fn decideOperationFor(self: *const Backend, amount: i32) !void {
        const message: ClientMessage = if (amount > 0) .increase else .decrease;
        const step: i32 = if (amount > 0) -1 else 1;
        var remaining = amount;

        while (remaining != 0) : (remaining += step) {
            try self.io.checkCancel();
            try postRequired(ClientMessage, self.client_sink, message);
        }
    }
};

pub const BackendMessage = union(enum) {
    decide_operation_for: i32,
};

fn readInput(io: std.Io, sink: *GenericInbox(ClientMessage), input: std.Io.File) !void {
    var bytes: [64]u8 = undefined;
    while (true) {
        const count = try input.readStreaming(io, &.{&bytes});
        if (count == 0) {
            try postRequired(ClientMessage, sink, .quit);
            return;
        }

        for (bytes[0..count]) |byte| {
            const message: ClientMessage = switch (byte) {
                'q', 3 => .quit,
                '+' => .{ .request_operation = 1 },
                '-' => .{ .request_operation = -1 },
                else => continue,
            };
            try postRequired(ClientMessage, sink, message);
            if (message == .quit) {
                return;
            }
        }
    }
}

pub fn main(init: std.process.Init) !void {
    var tty = try frontend.Tty.open();
    defer tty.deinit();

    var output_storage: [512 * 1024]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &output_storage);
    const writer = &output.interface;
    defer {
        writer.writeAll(frontend.leave) catch {};
        writer.flush() catch {};
    }

    try writer.writeAll(frontend.enter);
    try writer.flush();
    const size = tty.size();
    var screen = try frontend.Screen.init(init.gpa, size.cols, size.rows);
    defer screen.deinit();

    var terminal: TerminalRenderer = .{ .screen = &screen, .writer = writer, .tty = &tty };
    var renderer: Renderer = .{ .context = &terminal, .render_fn = TerminalRenderer.render };
    try run(init.io, &renderer, .stdin());
}

/// Runs the same actors for either host. Example: try run(io, &renderer, input);
pub fn run(io: std.Io, renderer: *Renderer, input: std.Io.File) !void {
    var model: Model = .{ .counter = .{ .value = 0 } };
    var backend_storage: [8]BackendMessage = undefined;
    var backend_message_queue: std.Io.Queue(BackendMessage) = .init(&backend_storage);
    // Room for the sample requests and unit replies; required-message overflow fails.
    var client_storage: [64]ClientMessage = undefined;
    var client_message_queue: std.Io.Queue(ClientMessage) = .init(&client_storage);
    var backend_adapter: QueueInbox(BackendMessage) = .{
        .io = io,
        .queue = &backend_message_queue,
    };
    var client_adapter: QueueInbox(ClientMessage) = .{
        .io = io,
        .queue = &client_message_queue,
    };
    var backend_sink = backend_adapter.inbox();
    var backend_receiver = backend_adapter.inboxReceiver();
    var client_sink = client_adapter.inbox();
    var client_receiver = client_adapter.inboxReceiver();

    const backend_loop: BackendLoop = .{
        .receiver = &backend_receiver,
        .backend = .{ .io = io, .client_sink = &client_sink },
    };
    const client_loop: ClientLoop = .{
        .receiver = &client_receiver,
        .model = &model,
        .context = .{ .backend_sink = &backend_sink },
        .renderer = renderer,
    };
    const script: ScriptProducer = .{
        .io = io,
        .client_sink = &client_sink,
        .amounts = &.{ 3, -2, 0 },
    };
    const ticker: FrameTicker = .{ .io = io, .client_sink = &client_sink };

    // Observe task failures without using either data inbox for supervision.
    // Cancellation finishes before any borrowed adapters, handles or buffers die.
    var completions: [5]TaskResult = undefined;
    var tasks = std.Io.Select(TaskResult).init(io, &completions);
    defer tasks.cancelDiscard();

    try renderer.render(model.counter.value);
    try tasks.concurrent(.input, readInput, .{ io, &client_sink, input });
    try tasks.concurrent(.backend, BackendLoop.run, .{backend_loop});
    try tasks.concurrent(.client, ClientLoop.run, .{client_loop});
    try tasks.concurrent(.script, ScriptProducer.run, .{script});
    try tasks.concurrent(.ticker, FrameTicker.run, .{ticker});
    try awaitTasks(&tasks);
}

const TaskResult = union(enum) {
    backend: anyerror!void,
    client: anyerror!void,
    script: anyerror!void,
    ticker: anyerror!void,
    input: anyerror!void,
};

fn awaitTasks(tasks: *std.Io.Select(TaskResult)) !void {
    while (true) {
        switch (try tasks.await()) {
            .script, .input => |result| try result,
            .backend, .client, .ticker => |result| {
                try result;
                return;
            },
        }
    }
}

fn postRequired(comptime Message: type, sink: *GenericInbox(Message), message: Message) error{ InboxFull, InboxClosed }!void {
    switch (sink.post(message)) {
        .accepted => {},
        .full => return error.InboxFull,
        .closed => return error.InboxClosed,
    }
}

test {
    _ = widgets;
}

test "sender and receiver share admission, ordering and close-after-drain" {
    const io = std.testing.io;
    var storage: [2]u32 = undefined;
    var queue: std.Io.Queue(u32) = .init(&storage);
    var adapter: QueueInbox(u32) = .{ .io = io, .queue = &queue };
    var sender = adapter.inbox();
    var receiver = adapter.inboxReceiver();

    try std.testing.expectEqual(.accepted, sender.post(11));
    try std.testing.expectEqual(.accepted, sender.post(22));
    try std.testing.expectEqual(.full, sender.post(33));
    queue.close(io);
    try std.testing.expectEqual(.closed, sender.post(44));
    try std.testing.expectEqual(@as(u32, 11), try receiver.pull());
    try std.testing.expectEqual(@as(u32, 22), try receiver.pull());
    try std.testing.expectError(error.Closed, receiver.pull());
}

test "two concurrent producers publish to one receiver" {
    const io = std.testing.io;
    var storage: [2]u32 = undefined;
    var queue: std.Io.Queue(u32) = .init(&storage);
    var adapter: QueueInbox(u32) = .{ .io = io, .queue = &queue };
    var sender = adapter.inbox();
    var receiver = adapter.inboxReceiver();
    var first = try io.concurrent(GenericInbox(u32).post, .{ &sender, 11 });
    defer _ = first.cancel(io);

    var second = try io.concurrent(GenericInbox(u32).post, .{ &sender, 22 });
    defer _ = second.cancel(io);

    try std.testing.expectEqual(.accepted, first.await(io));
    try std.testing.expectEqual(.accepted, second.await(io));
    const a = try receiver.pull();
    const b = try receiver.pull();
    try std.testing.expect((a == 11 and b == 22) or (a == 22 and b == 11));
}

test "an empty receive can be canceled without closing the inbox" {
    const io = std.testing.io;
    var storage: [1]u32 = undefined;
    var queue: std.Io.Queue(u32) = .init(&storage);
    var adapter: QueueInbox(u32) = .{ .io = io, .queue = &queue };
    var sender = adapter.inbox();
    var receiver = adapter.inboxReceiver();
    var task = try io.concurrent(GenericInboxReceiver(u32).pull, .{&receiver});
    defer _ = task.cancel(io) catch {};

    try std.testing.expectError(error.Canceled, task.cancel(io));
    try std.testing.expectEqual(.accepted, sender.post(42));
    try std.testing.expectEqual(@as(u32, 42), try receiver.pull());
}

test "script requests pass through the client and backend before updating the model" {
    const io = std.testing.io;
    var backend_storage: [3]BackendMessage = undefined;
    var backend_queue: std.Io.Queue(BackendMessage) = .init(&backend_storage);
    var client_storage: [8]ClientMessage = undefined;
    var client_queue: std.Io.Queue(ClientMessage) = .init(&client_storage);
    var backend_adapter: QueueInbox(BackendMessage) = .{ .io = io, .queue = &backend_queue };
    var client_adapter: QueueInbox(ClientMessage) = .{ .io = io, .queue = &client_queue };
    var backend_sender = backend_adapter.inbox();
    var backend_receiver = backend_adapter.inboxReceiver();
    var client_sender = client_adapter.inbox();
    var client_receiver = client_adapter.inboxReceiver();
    var model: Model = .{ .counter = .{} };
    var rendered: i32 = -100;
    var renderer: Renderer = .{ .context = &rendered, .render_fn = recordRender };
    const client_loop: ClientLoop = .{
        .receiver = &client_receiver,
        .model = &model,
        .context = .{ .backend_sink = &backend_sender },
        .renderer = &renderer,
    };
    const backend_loop: BackendLoop = .{
        .receiver = &backend_receiver,
        .backend = .{ .io = io, .client_sink = &client_sender },
    };
    const script: ScriptProducer = .{
        .io = io,
        .client_sink = &client_sender,
        .amounts = &.{ 3, -2, 0 },
        .interval_ms = 0,
    };

    try script.run();

    for (script.amounts) |amount| {
        const message = try client_receiver.pull();
        try std.testing.expectEqual(amount, message.request_operation);
        try client_loop.handle(message);
    }

    try std.testing.expectEqual(@as(i32, 0), model.counter.value);
    backend_queue.close(io);
    try backend_loop.run();
    try std.testing.expectEqual(@as(i32, -100), rendered);
    try std.testing.expectEqual(.accepted, client_sender.post(.render));
    client_queue.close(io);
    try client_loop.run();
    try std.testing.expectEqual(@as(i32, 1), model.counter.value);
    try std.testing.expectEqual(@as(i32, 1), rendered);
}

test "context reports backend admission failure instead of pretending success" {
    const io = std.testing.io;
    var storage: [1]BackendMessage = undefined;
    var queue: std.Io.Queue(BackendMessage) = .init(&storage);
    var adapter: QueueInbox(BackendMessage) = .{ .io = io, .queue = &queue };
    var sender = adapter.inbox();
    const context: FrontendContext = .{ .backend_sink = &sender };

    try context.requestBackend(.{ .decide_operation_for = 3 });
    try std.testing.expectError(error.InboxFull, context.requestBackend(.{ .decide_operation_for = -2 }));
    queue.close(io);
    try std.testing.expectError(error.InboxClosed, context.requestBackend(.{ .decide_operation_for = 0 }));
}

test "script and backend fail explicitly when required messages cannot fit" {
    const io = std.testing.io;
    var storage: [1]ClientMessage = undefined;
    var queue: std.Io.Queue(ClientMessage) = .init(&storage);
    var adapter: QueueInbox(ClientMessage) = .{ .io = io, .queue = &queue };
    var sender = adapter.inbox();
    var receiver = adapter.inboxReceiver();
    const script: ScriptProducer = .{
        .io = io,
        .client_sink = &sender,
        .amounts = &.{ 3, -2 },
        .interval_ms = 0,
    };
    const backend: Backend = .{ .io = io, .client_sink = &sender };

    try std.testing.expectError(error.InboxFull, script.run());
    try std.testing.expectEqual(@as(i32, 3), (try receiver.pull()).request_operation);
    try std.testing.expectError(error.InboxFull, backend.decideOperationFor(2));
    try std.testing.expectEqual(ClientMessage.increase, try receiver.pull());
    queue.close(io);
    try std.testing.expectError(error.InboxClosed, script.run());
    try std.testing.expectError(error.InboxClosed, backend.decideOperationFor(-1));
}

test "ticker skips full admission and stops on a closed publication handle" {
    const FakeSink = struct {
        calls: usize = 0,

        fn post(context: *anyopaque, message: ClientMessage) GenericInbox(ClientMessage).Result {
            const self: *@This() = @ptrCast(@alignCast(context));
            std.debug.assert(message == .render);
            self.calls += 1;

            return switch (self.calls) {
                1 => .full,
                2 => .accepted,
                else => .closed,
            };
        }
    };
    var fake: FakeSink = .{};
    var sender: GenericInbox(ClientMessage) = .{ .context = &fake, .post_fn = FakeSink.post };
    const ticker: FrameTicker = .{ .io = std.testing.io, .client_sink = &sender, .interval_ms = 1 };

    try ticker.run();
    try std.testing.expectEqual(@as(usize, 3), fake.calls);
}

test "ticker wakes a receiver and terminates after queue closure" {
    const io = std.testing.io;
    var storage: [1]ClientMessage = undefined;
    var queue: std.Io.Queue(ClientMessage) = .init(&storage);
    var adapter: QueueInbox(ClientMessage) = .{ .io = io, .queue = &queue };
    var sender = adapter.inbox();
    var receiver = adapter.inboxReceiver();
    const ticker: FrameTicker = .{ .io = io, .client_sink = &sender, .interval_ms = 1 };
    var task = try io.concurrent(FrameTicker.run, .{ticker});
    defer _ = task.cancel(io) catch {};

    try std.testing.expectEqual(ClientMessage.render, try receiver.pull());
    try std.testing.expectEqual(ClientMessage.render, try receiver.pull());
    queue.close(io);
    try task.await(io);
}

test "supervision reports task failure even when the script can finish normally" {
    const Workers = struct {
        fn finish() anyerror!void {}

        fn fail() anyerror!void {
            return error.WorkerFailed;
        }
    };
    var storage: [4]TaskResult = undefined;
    var tasks = std.Io.Select(TaskResult).init(std.testing.io, &storage);
    defer tasks.cancelDiscard();

    try tasks.concurrent(.script, Workers.finish, .{});
    try tasks.concurrent(.backend, Workers.fail, .{});
    try std.testing.expectError(error.WorkerFailed, awaitTasks(&tasks));
}

fn recordRender(context: *anyopaque, value: i32) !void {
    const recorded: *i32 = @ptrCast(@alignCast(context));
    recorded.* = value;
}
