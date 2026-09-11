const std = @import("std");
const Key = @import("Key.zig");
const chord = @import("chord.zig");
const keybind = @import("keybind.zig");

pub fn Type(comptime Action: type, comptime max_keys: usize) type {
    if (max_keys == 0 or max_keys > std.math.maxInt(u8)) {
        @compileError("max_keys must fit in a non-zero u8");
    }

    return struct {
        // Fully initialized so configuration values remain safe to copy as a
        // whole struct even though comparisons inspect only `len` keys.
        keys: [max_keys]Key = @splat(.plain(.escape)),
        len: u8,
        action: Action,

        const Self = @This();

        pub fn init(keys: []const Key, action: Action) !Self {
            if (keys.len == 0) {
                return error.EmptySequence;
            }
            if (keys.len > max_keys) {
                return error.SequenceTooLong;
            }
            var binding: Self = .{ .len = @intCast(keys.len), .action = action };
            @memcpy(binding.keys[0..keys.len], keys);
            return binding;
        }

        pub fn parse(names: []const []const u8, action: Action) !Self {
            if (names.len == 0) {
                return error.EmptySequence;
            }
            if (names.len > max_keys) {
                return error.SequenceTooLong;
            }
            var binding: Self = .{ .len = @intCast(names.len), .action = action };
            for (names, 0..) |name, index| binding.keys[index] = try chord.parseKey(name);
            return binding;
        }

        pub fn sameSequence(a: *const Self, b: *const Self) bool {
            return keybind.sequenceOrder(a.slice(), b.slice()) == .eq;
        }

        /// True when one sequence equals or prefixes the other — the same
        /// overlap Keymap.init rejects as duplicate or ambiguous.
        pub fn conflictsWith(a: *const Self, b: *const Self) bool {
            const shared = keybind.commonPrefix(a.slice(), b.slice());
            return shared == a.len or shared == b.len;
        }

        pub fn slice(binding: *const Self) []const Key {
            return binding.keys[0..binding.len];
        }
    };
}
