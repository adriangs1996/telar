const data = @import("model");
const std = @import("std");

pub fn Type(comptime Action: type, comptime max_bindings: usize, comptime max_keys: usize) type {
    if (max_bindings == 0 or max_bindings > std.math.maxInt(u16)) {
        @compileError("max_bindings must fit in a non-zero u16");
    }

    const BindingType = data.GenericBinding(Action, max_keys);
    return struct {
        bindings: [max_bindings]BindingType = undefined,
        order: [max_bindings]u16 = undefined,
        len: u16 = 0,

        const Self = @This();

        pub fn init(configured: []const BindingType) !Self {
            if (configured.len > max_bindings) {
                return error.TooManyBindings;
            }
            var map: Self = .{ .len = @intCast(configured.len) };
            for (configured, 0..) |binding, index| map.bindings[index] = binding;
            for (map.order[0..map.len], 0..) |*slot, index| slot.* = @intCast(index);
            // Sort small integer indices, not unions with inactive payloads and
            // padding. Configuration compilation moves two bytes at a time
            // instead of an entire binding.
            var unsorted: usize = 1;
            while (unsorted < map.len) : (unsorted += 1) {
                const candidate = map.order[unsorted];
                var position = unsorted;
                while (position > 0 and orderLessThan(&map.bindings, candidate, map.order[position - 1])) {
                    map.order[position] = map.order[position - 1];
                    position -= 1;
                }
                map.order[position] = candidate;
            }

            var index: usize = 1;
            while (index < map.len) : (index += 1) {
                const previous = map.bindingAt(index - 1);
                const current = map.bindingAt(index);
                const shared = data.keybind.commonPrefix(previous.slice(), current.slice());
                if (shared == previous.len or shared == current.len) {
                    if (previous.len == current.len) {
                        return error.DuplicateBinding;
                    }
                    return error.AmbiguousBindingPrefix;
                }
            }
            return map;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len == 0;
        }

        pub const Range = struct { start: usize, end: usize };
        const Match = struct { depth: usize, key: data.Key };

        pub fn matchingRange(self: *const Self, range: Range, match: Match) ?Range {
            var low = range.start;
            var high = range.end;
            while (low < high) {
                const middle = low + (high - low) / 2;
                if (data.keybind.keyOrder(self.bindingAt(middle).keys[match.depth], match.key) == .lt) {
                    low = middle + 1;
                } else {
                    high = middle;
                }
            }
            const start = low;

            high = range.end;
            while (low < high) {
                const middle = low + (high - low) / 2;
                if (data.keybind.keyOrder(self.bindingAt(middle).keys[match.depth], match.key) == .gt) {
                    high = middle;
                } else {
                    low = middle + 1;
                }
            }
            if (start == low) {
                return null;
            }
            return .{ .start = start, .end = low };
        }

        pub fn bindingAt(self: *const Self, sorted_index: usize) *const BindingType {
            return &self.bindings[self.order[sorted_index]];
        }

        fn orderLessThan(bindings: *const [max_bindings]BindingType, a: u16, b: u16) bool {
            return data.keybind.sequenceOrder(bindings[a].slice(), bindings[b].slice()) == .lt;
        }
    };
}
