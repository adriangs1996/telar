//! Bounded producer admission, completion storage and consumer wakeups.
//! Workers use std.Io.Group; only the adapter's consumer dispatches messages.
const std = @import("std");
const Ticket = @import("ProducerTicket.zig");
const Wakeup = @import("Wakeup.zig");
const Snapshot = @import("InboxSnapshot.zig");
const DrainBudget = @import("DrainBudget.zig");

/// Message values own their data or retain an explicit owner-side borrow.
/// A consumer whose producers can hold more than `default_capacity`
/// tickets at once declares `pub const inbox_capacity` on `Message`, up to
/// `max_capacity`.
/// Example: `const Inbox = GenericInbox(ClientEvent);`
pub fn Type(comptime Message: type) type {
    return struct {
        const Inbox = @This();
        const Field = std.meta.FieldEnum(Message);
        const SlotState = enum { free, reserved, ready };
        pub const default_capacity = 64;
        /// Tickets name their slot in a byte.
        pub const max_capacity = std.math.maxInt(u8) + 1;
        pub const capacity: usize = if (@hasDecl(Message, "inbox_capacity")) Message.inbox_capacity else default_capacity;

        comptime {
            std.debug.assert(capacity > 0 and capacity <= max_capacity);
        }

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
        pub fn reserve(self: *Inbox) !Ticket {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.claim();
        }

        fn claim(self: *Inbox) !Ticket {
            if (!self.accepting) {
                return error.InboxClosed;
            }

            for (&self.states, 0..) |*state, slot| {
                if (state.* != .free) {
                    continue;
                }

                state.* = .reserved;
                self.generations[slot] += 1;
                self.reserved += 1;
                self.counters.high_water = @max(self.counters.high_water, self.len + self.reserved);
                return .{ .slot = @intCast(slot), .generation = self.generations[slot] };
            }

            self.counters.rejected +|= 1;
            return error.InboxFull;
        }

        /// A producer publishes only into its own reservation. Invalidated
        /// results never reach the model. Example: `_ = inbox.publish(ticket, event);`
        pub fn publish(self: *Inbox, ticket: Ticket, message: Message) bool {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (!self.valid(ticket)) {
                self.counters.stale +|= 1;
                return false;
            }

            if (!self.accepting) {
                self.states[ticket.slot] = .free;
                self.reserved -= 1;
                self.counters.stale +|= 1;
                return false;
            }

            self.append(ticket, message);
            return true;
        }

        fn append(self: *Inbox, ticket: Ticket, message: Message) void {
            self.items[ticket.slot] = message;
            self.states[ticket.slot] = .ready;
            self.order[(self.head + self.len) % capacity] = ticket.slot;
            self.reserved -= 1;
            self.len += 1;
            self.counters.admitted +|= 1;
            if (self.len == 1) {
                self.signal();
            }
        }

        /// Releases admission if a worker could not start. Example: `inbox.release(ticket);`
        pub fn release(self: *Inbox, ticket: Ticket) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.valid(ticket)) {
                self.states[ticket.slot] = .free;
                self.reserved -= 1;
            }
        }

        fn valid(self: *const Inbox, ticket: Ticket) bool {
            return ticket.slot < capacity and self.states[ticket.slot] == .reserved and self.generations[ticket.slot] == ticket.generation;
        }

        /// Copies one owned local message without waiting for capacity.
        /// Example: `try inbox.post(.{ .focus = true });`
        pub fn post(self: *Inbox, message: Message) !void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.append(try self.claim(), message);
        }

        /// Use only for replaceable notifications, never input bytes or deltas.
        /// Example: `try inbox.notify(.input_ready);`
        pub fn notify(self: *Inbox, message: Message) !void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            if (!self.accepting) {
                return error.InboxClosed;
            }

            for (0..self.len) |offset| {
                const slot = self.order[(self.head + offset) % capacity];

                if (@as(Field, self.items[slot]) == @as(Field, message)) {
                    self.items[slot] = message;
                    self.counters.coalesced +|= 1;
                    return;
                }
            }

            self.append(try self.claim(), message);
        }

        /// The consumer starts work through std.Io's task group. External
        /// producers only publish into previously issued reservations.
        /// Example: `try inbox.start(.sent, .{ send, .{ io, request } });`
        pub fn start(self: *Inbox, comptime field: Field, work: anytype) !void {
            const ticket = try self.reserve();
            errdefer self.release(ticket);
            const Task = struct {
                fn run(owner: *Inbox, reservation: Ticket, job: @TypeOf(work)) void {
                    const result = @call(.auto, job[0], job[1]);
                    _ = owner.publish(reservation, @unionInit(Message, @tagName(field), result));
                }
            };
            try self.tasks.concurrent(self.io, Task.run, .{ self, ticket, work });
        }

        /// The blocking host sleeps here only while there are no messages.
        /// Example: `try inbox.wait();`
        pub fn wait(self: *Inbox) !void {
            try self.ready.wait(self.io);
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (!self.accepting and self.len == 0) {
                return error.InboxClosed;
            }
        }

        /// Single-message consumption for deterministic adapters and tests.
        /// Example: `const event = try inbox.receive();`
        pub fn receive(self: *Inbox) !Message {
            while (true) {
                if (try self.pop()) |message| {
                    return message;
                }

                try self.wait();
            }
        }

        fn pop(self: *Inbox) !?Message {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.len == 0) {
                if (!self.accepting) {
                    return error.InboxClosed;
                }

                return null;
            }

            const slot = self.order[self.head];
            const message = self.items[slot];
            self.head = (self.head + 1) % capacity;
            self.len -= 1;
            self.states[slot] = .free;
            self.counters.consumed +|= 1;
            if (self.len == 0 and self.accepting) {
                self.ready.reset();
            }

            return message;
        }

        /// Captures the current FIFO boundary and prevents reentrant dispatch.
        /// Example: `var turn = try inbox.begin(); defer inbox.end();`
        pub fn begin(self: *Inbox) !DrainBudget {
            if (self.draining) {
                return error.ReentrantClientDispatch;
            }

            self.draining = true;
            const state = self.snapshot();
            return DrainBudget.begin(self.io, state.depth);
        }

        /// Example: `while (try inbox.next(&turn)) |event| { ... }`
        pub fn next(self: *Inbox, budget: *DrainBudget) !?Message {
            std.debug.assert(self.draining);
            if (!budget.take(self.io)) {
                return null;
            }

            return self.pop();
        }

        /// Rearms a native wake when a finite drain leaves work behind.
        /// Example: `defer inbox.end();`
        pub fn end(self: *Inbox) void {
            std.debug.assert(self.draining);
            self.draining = false;
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.len != 0 and self.accepting) {
                self.counters.budget_yields +|= 1;
                self.signal();
            }
        }

        fn signal(self: *Inbox) void {
            self.ready.set(self.io);
            self.counters.wakes +|= 1;
            self.wakeup.notify();
        }

        /// No more work is admitted; blocked consumers wake for teardown.
        /// Example: `inbox.close();`
        pub fn close(self: *Inbox) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.accepting = false;
            self.ready.set(self.io);
        }

        /// Join before freeing producer buffers or the wake endpoint. Result
        /// resources remain in their adapter owners. Example: `inbox.deinit();`
        pub fn deinit(self: *Inbox) void {
            self.close();
            self.tasks.cancel(self.io);
        }

        /// Example: `const stats = inbox.snapshot();`
        pub fn snapshot(self: *Inbox) Snapshot {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            var result = self.counters;
            result.depth = self.len;
            result.storage_bytes = @sizeOf(Inbox);
            result.reserved = self.reserved;
            return result;
        }
    };
}
