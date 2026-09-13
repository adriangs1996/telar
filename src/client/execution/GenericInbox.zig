//! Bounded producer admission, completion storage and consumer wakeups.
//! Workers use std.Io.Group; only the adapter's consumer dispatches messages.
const std = @import("std");
const Ticket = @import("ProducerTicket.zig");
const Wakeup = @import("Wakeup.zig");
const Snapshot = @import("InboxSnapshot.zig");
const DrainBudget = @import("DrainBudget.zig");

/// Message values own their data or retain an explicit owner-side borrow.
/// Example: `const Inbox = GenericInbox(ClientEvent);`
pub fn Type(comptime Message: type) type {
    return struct {
        const Inbox = @This();
        const Field = std.meta.FieldEnum(Message);
        const SlotState = enum { free, reserved, ready };
        pub const capacity = 64;

        io: std.Io,
        wakeup: Wakeup = .{},
        tasks: std.Io.Group = .init,
        mutex: std.Io.Mutex = .init,
        ready: std.Io.Event = .unset,
        items: [capacity]Message = undefined,
        states: [capacity]SlotState = @splat(.free),
        generations: [capacity]u64 = @splat(0),
        order: [capacity]u8 = undefined,
        head: usize = 0,
        len: usize = 0,
        reserved: usize = 0,
        accepting: bool = true,
        draining: bool = false,
        counters: Snapshot = .{},

        /// Initialize at a stable address before starting any producer.
        /// Example: `inbox.* = .init(io, wakeup);`
        pub fn init(io: std.Io, wakeup: Wakeup) Inbox {
            return .{ .io = io, .wakeup = wakeup };
        }

        /// Reserve capacity before invoking a worker. Its completion cannot fill
        /// the queue unexpectedly. Example: `const ticket = try inbox.reserve();`
        pub fn reserve(inbox: *Inbox) !Ticket {
            inbox.mutex.lockUncancelable(inbox.io);
            defer inbox.mutex.unlock(inbox.io);
            return inbox.claim();
        }

        fn claim(inbox: *Inbox) !Ticket {
            if (!inbox.accepting) {
                return error.InboxClosed;
            }

            for (&inbox.states, 0..) |*state, slot| {
                if (state.* != .free) {
                    continue;
                }

                state.* = .reserved;
                inbox.generations[slot] += 1;
                inbox.reserved += 1;
                inbox.counters.high_water = @max(inbox.counters.high_water, inbox.len + inbox.reserved);
                return .{ .slot = @intCast(slot), .generation = inbox.generations[slot] };
            }

            inbox.counters.rejected +|= 1;
            return error.InboxFull;
        }

        /// A producer publishes only into its own reservation. Invalidated
        /// results never reach the model. Example: `_ = inbox.publish(ticket, event);`
        pub fn publish(inbox: *Inbox, ticket: Ticket, message: Message) bool {
            inbox.mutex.lockUncancelable(inbox.io);
            defer inbox.mutex.unlock(inbox.io);
            if (!inbox.valid(ticket)) {
                inbox.counters.stale +|= 1;
                return false;
            }

            if (!inbox.accepting) {
                inbox.states[ticket.slot] = .free;
                inbox.reserved -= 1;
                inbox.counters.stale +|= 1;
                return false;
            }

            inbox.append(ticket, message);
            return true;
        }

        fn append(inbox: *Inbox, ticket: Ticket, message: Message) void {
            inbox.items[ticket.slot] = message;
            inbox.states[ticket.slot] = .ready;
            inbox.order[(inbox.head + inbox.len) % capacity] = ticket.slot;
            inbox.reserved -= 1;
            inbox.len += 1;
            inbox.counters.admitted +|= 1;
            if (inbox.len == 1) {
                inbox.signal();
            }
        }

        /// Releases admission if a worker could not start. Example: `inbox.release(ticket);`
        pub fn release(inbox: *Inbox, ticket: Ticket) void {
            inbox.mutex.lockUncancelable(inbox.io);
            defer inbox.mutex.unlock(inbox.io);
            if (inbox.valid(ticket)) {
                inbox.states[ticket.slot] = .free;
                inbox.reserved -= 1;
            }
        }

        fn valid(inbox: *const Inbox, ticket: Ticket) bool {
            return ticket.slot < capacity and inbox.states[ticket.slot] == .reserved and inbox.generations[ticket.slot] == ticket.generation;
        }

        /// Copies one owned local message without waiting for capacity.
        /// Example: `try inbox.post(.{ .focus = true });`
        pub fn post(inbox: *Inbox, message: Message) !void {
            inbox.mutex.lockUncancelable(inbox.io);
            defer inbox.mutex.unlock(inbox.io);
            inbox.append(try inbox.claim(), message);
        }

        /// Use only for replaceable notifications, never input bytes or deltas.
        /// Example: `try inbox.notify(.input_ready);`
        pub fn notify(inbox: *Inbox, message: Message) !void {
            inbox.mutex.lockUncancelable(inbox.io);
            defer inbox.mutex.unlock(inbox.io);
            if (!inbox.accepting) {
                return error.InboxClosed;
            }

            for (0..inbox.len) |offset| {
                const slot = inbox.order[(inbox.head + offset) % capacity];
                if (@as(Field, inbox.items[slot]) == @as(Field, message)) {
                    inbox.items[slot] = message;
                    inbox.counters.coalesced +|= 1;
                    return;
                }
            }

            inbox.append(try inbox.claim(), message);
        }

        /// The consumer starts work through std.Io's task group. External
        /// producers only publish into previously issued reservations.
        /// Example: `try inbox.start(.sent, .{ send, .{ io, request } });`
        pub fn start(inbox: *Inbox, comptime field: Field, work: anytype) !void {
            const ticket = try inbox.reserve();
            errdefer inbox.release(ticket);
            const Task = struct {
                fn run(owner: *Inbox, reservation: Ticket, job: @TypeOf(work)) void {
                    const result = @call(.auto, job[0], job[1]);
                    _ = owner.publish(reservation, @unionInit(Message, @tagName(field), result));
                }
            };
            try inbox.tasks.concurrent(inbox.io, Task.run, .{ inbox, ticket, work });
        }

        /// The blocking host sleeps here only while there are no messages.
        /// Example: `try inbox.wait();`
        pub fn wait(inbox: *Inbox) !void {
            try inbox.ready.wait(inbox.io);
            inbox.mutex.lockUncancelable(inbox.io);
            defer inbox.mutex.unlock(inbox.io);
            if (!inbox.accepting and inbox.len == 0) {
                return error.InboxClosed;
            }
        }

        /// Single-message consumption for deterministic adapters and tests.
        /// Example: `const event = try inbox.receive();`
        pub fn receive(inbox: *Inbox) !Message {
            while (true) {
                if (try inbox.pop()) |message| {
                    return message;
                }

                try inbox.wait();
            }
        }

        fn pop(inbox: *Inbox) !?Message {
            inbox.mutex.lockUncancelable(inbox.io);
            defer inbox.mutex.unlock(inbox.io);
            if (inbox.len == 0) {
                if (!inbox.accepting) {
                    return error.InboxClosed;
                }

                return null;
            }

            const slot = inbox.order[inbox.head];
            const message = inbox.items[slot];
            inbox.head = (inbox.head + 1) % capacity;
            inbox.len -= 1;
            inbox.states[slot] = .free;
            inbox.counters.consumed +|= 1;
            if (inbox.len == 0 and inbox.accepting) {
                inbox.ready.reset();
            }

            return message;
        }

        /// Captures the current FIFO boundary and prevents reentrant dispatch.
        /// Example: `var turn = try inbox.begin(); defer inbox.end();`
        pub fn begin(inbox: *Inbox) !DrainBudget {
            if (inbox.draining) {
                return error.ReentrantClientDispatch;
            }

            inbox.draining = true;
            const state = inbox.snapshot();
            return DrainBudget.begin(inbox.io, state.depth);
        }

        /// Example: `while (try inbox.next(&turn)) |event| { ... }`
        pub fn next(inbox: *Inbox, budget: *DrainBudget) !?Message {
            std.debug.assert(inbox.draining);
            if (!budget.take(inbox.io)) {
                return null;
            }

            return inbox.pop();
        }

        /// Rearms a native wake when a finite drain leaves work behind.
        /// Example: `defer inbox.end();`
        pub fn end(inbox: *Inbox) void {
            std.debug.assert(inbox.draining);
            inbox.draining = false;
            inbox.mutex.lockUncancelable(inbox.io);
            defer inbox.mutex.unlock(inbox.io);
            if (inbox.len != 0 and inbox.accepting) {
                inbox.counters.budget_yields +|= 1;
                inbox.signal();
            }
        }

        fn signal(inbox: *Inbox) void {
            inbox.ready.set(inbox.io);
            inbox.counters.wakes +|= 1;
            inbox.wakeup.notify();
        }

        /// No more work is admitted; blocked consumers wake for teardown.
        /// Example: `inbox.close();`
        pub fn close(inbox: *Inbox) void {
            inbox.mutex.lockUncancelable(inbox.io);
            defer inbox.mutex.unlock(inbox.io);
            inbox.accepting = false;
            inbox.ready.set(inbox.io);
        }

        /// Join before freeing producer buffers or the wake endpoint. Result
        /// resources remain in their adapter owners. Example: `inbox.deinit();`
        pub fn deinit(inbox: *Inbox) void {
            inbox.close();
            inbox.tasks.cancel(inbox.io);
        }

        /// Example: `const stats = inbox.snapshot();`
        pub fn snapshot(inbox: *Inbox) Snapshot {
            inbox.mutex.lockUncancelable(inbox.io);
            defer inbox.mutex.unlock(inbox.io);
            var result = inbox.counters;
            result.depth = inbox.len;
            result.storage_bytes = @sizeOf(Inbox);
            result.reserved = inbox.reserved;
            return result;
        }
    };
}
