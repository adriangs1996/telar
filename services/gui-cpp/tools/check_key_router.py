import argparse
import itertools
import json
import os
from pathlib import Path
import random
import struct
import subprocess
import tempfile


key_names = ("ctrl+b", "s", "g", "h", "space", "escape", "u", "a", "b", "c", "d", "e", "🌱", "left", "alt+q")
bindings = (((0, 1), 1), ((2, 2), 2), ((7, 8, 9, 10, 11), 3), ((12,), 4), ((14, 6), 5))
record_words = 10
result_words = 31
result_bytes = result_words * struct.calcsize("<I")


cpp_probe = r"""
#include "input/key_router.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include <array>
#include <bit>
#include <cstdint>
#include <cstring>
#include <initializer_list>
#include <iostream>
#include <optional>
#include <span>
#include <string_view>

using namespace telar::gui;
using Router = KeyRouter<std::uint32_t>;
using Decision = Router::Decision;

constexpr std::array<std::string_view, @key_count@> names{@names@};

KeyChord parse(std::string_view name) {
  KeyChord key;
  if (name.starts_with("ctrl+")) {
    key.modifiers = static_cast<unsigned>(KeyChord::Modifier::control);
    name.remove_prefix(std::string_view{"ctrl+"}.size());
  } else if (name.starts_with("alt+")) {
    key.modifiers = static_cast<unsigned>(KeyChord::Modifier::alt);
    name.remove_prefix(std::string_view{"alt+"}.size());
  }

  if (name == "escape") {
    key.key = KeyChord::Key::escape;
  } else if (name == "left") {
    key.key = KeyChord::Key::left;
  } else {
    if (name == "space") { name = " "; }
    std::memcpy(&key.character, name.data(), name.size());
  }

  return key;
}

const auto keys = [] {
  std::array<KeyChord, names.size()> result{};
  for (std::size_t index = 0; index < result.size(); ++index) { result[index] = parse(names[index]); }
  return result;
}();

KeyBinding<std::uint32_t> binding(std::initializer_list<std::size_t> indices, std::uint32_t action) {
  KeyBinding<std::uint32_t> result{.length = indices.size(), .action = action};
  std::size_t index = 0;
  for (const auto key : indices) { result.keys[index++] = keys[key]; }
  return result;
}

Router makeRouter(bool empty = false) {
  const std::array bindings{@bindings@};
  return Router{empty ? BindingMap<std::uint32_t>{} : BindingMap<std::uint32_t>{bindings}, keys[0]};
}

std::optional<BindingRepeat> policy(std::uint32_t action, std::uint32_t owner) {
  return action == 1 && owner != 0 ? std::optional{BindingRepeat{.interval_ns = 100, .owner = owner}} : std::nullopt;
}

struct EventRecord {
  std::uint32_t key = 0;
  std::uint32_t phase = 0;
  std::uint32_t physical = 0;
};

struct ResultRecord {
  std::uint32_t outcome = 0;
  std::uint32_t action = 0;
  std::uint32_t repeated = 0;
  std::uint32_t held_count = 0;
  std::uint32_t has_current = 0;
  std::uint32_t prefix_pending = 0;
  std::uint32_t deadline_present = 0;
  std::uint32_t deadline_low = 0;
  std::uint32_t deadline_high = 0;
  std::uint32_t overflow_low = 0;
  std::uint32_t overflow_high = 0;
  std::uint32_t repeat_action = 0;
  std::uint32_t wants_binding = 0;
  EventRecord current;
  std::array<EventRecord, BindingLimits::keys> held{};
};

EventRecord eventRecord(const BindingEvent &event) {
  EventRecord result;
  for (std::size_t index = 0; index < keys.size(); ++index) {
    if (keys[index] == event.chord) {
      result.key = static_cast<std::uint32_t>(index);
      break;
    }
  }

  result.phase = static_cast<std::uint32_t>(event.phase) + 1;
  result.physical = static_cast<std::uint32_t>(event.physical);

  return result;
}

void emit(const Decision &decision, const Router &router, const BindingEvent &event) {
  constexpr unsigned word_bits = 32;
  ResultRecord result;
  result.outcome = static_cast<std::uint32_t>(decision.outcome);
  result.action = decision.outcome == Router::Outcome::action ? decision.action : 0;
  result.repeated = decision.repeated;
  result.held_count = static_cast<std::uint32_t>(decision.held_count);
  result.has_current = decision.has_current;
  result.prefix_pending = router.prefixPending();
  const auto due = router.deadline();
  result.deadline_present = due.has_value();
  result.deadline_low = static_cast<std::uint32_t>(due.value_or(0));
  result.deadline_high = static_cast<std::uint32_t>(due.value_or(0) >> word_bits);
  result.overflow_low = static_cast<std::uint32_t>(router.overflowCount());
  result.overflow_high = static_cast<std::uint32_t>(router.overflowCount() >> word_bits);
  result.repeat_action = router.repeatAction().value_or(0);
  result.wants_binding = router.wantsBinding(event);
  if (decision.outcome == Router::Outcome::forward || decision.outcome == Router::Outcome::action || decision.has_current) {
    result.current = eventRecord(decision.event);
  }

  for (std::size_t index = 0; index < decision.held_count; ++index) {
    result.held[index] = eventRecord(decision.held[index]);
  }

  constexpr auto record_words = sizeof(ResultRecord) / sizeof(std::uint32_t);
  const auto words = std::bit_cast<std::array<std::uint32_t, record_words>>(result);
  std::array<telar::Byte, sizeof(ResultRecord)> bytes{};
  std::span<telar::Byte> output{bytes};
  for (const auto word : words) {
    telar::u32::encode(word, output);
  }

  const auto text = telar::textView(bytes);
  std::cout.write(text.data(), static_cast<std::streamsize>(text.size()));
}

int main() {
  auto router = makeRouter();
  std::array<char, 10 * sizeof(std::uint32_t)> bytes{};
  while (std::cin.read(bytes.data(), bytes.size())) {
    auto input = telar::byteView({bytes.data(), bytes.size()});
    std::array<std::uint32_t, 10> record{};
    for (auto &word : record) { word = telar::u32::decode(input); }
    if (record[1] >= keys.size() || record[2] > 2) { return 1; }
    const BindingEvent event{.chord = keys[record[1]], .phase = static_cast<KeyPhase>(record[2]), .physical = record[3]};
    const auto now = record[4] | (static_cast<std::uint64_t>(record[5]) << 32);
    Decision decision;
    switch (record[0]) {
      case 0: router = makeRouter(); break;
      case 1: decision = router.route(event, now, {.captures_keys = record[6] != 0, .repeat = policy(router.repeatAction().value_or(0), record[7])}); break;
      case 2: decision = router.expire(now); break;
      case 3: decision = router.interrupt(); break;
      case 4: router.cancelSequence(); break;
      case 5: router.clear(); break;
      case 6: {
        auto replacement = makeRouter(record[8] != 0);
        replacement.inheritLeases(router);
        router = replacement;
        break;
      }
      case 7: router.eventFailed(event); break;
      case 8: router.relinquish(event.physical); break;
      default: return 1;
    }
    if (decision.outcome == Router::Outcome::action) { router.actionCompleted(decision, policy(decision.action, record[7])); }
    emit(decision, router, event);
  }
  return std::cin.gcount() == 0 && std::cin.eof() ? 0 : 1;
}
"""


zig_probe = r"""
const original = @import("keyinput");
extern "c" fn getchar() c_int;
extern "c" fn putchar(value: c_int) c_int;
const Router = original.GenericRouter(u32, .{ .max_bindings = 256, .max_keys = 5, .max_physical_leases = 64, .sequence_timeout_ns = 1_000_000_000 });
const Binding = original.GenericBinding(u32, 5);
const names = [_][]const u8{@names@};
const keys = makeKeys();

fn makeKeys() [names.len]original.Key {
    const chord_compile_quota = 100_000;
    @setEvalBranchQuota(chord_compile_quota);
    var result: [names.len]original.Key = undefined;
    for (names, 0..) |name, index| { result[index] = original.chord.parseKey(name) catch unreachable; }
    return result;
}

fn makeRouter(empty: bool) !Router {
    const bindings = [_]Binding{@bindings@};
    return Router.initWithPrefix(if (empty) &.{} else &bindings, keys[0]);
}

fn policy(action: u32, owner: u32) ?original.RepeatPolicy {
    return if (action == 1 and owner != 0) .{ .interval_ns = 100, .context = owner } else null;
}

fn readWord() !?u32 {
    const first = getchar();
    if (first < 0) { return null; }
    var word: u32 = @intCast(first);
    for (1..4) |index| {
        const byte = getchar();
        if (byte < 0) { return error.TruncatedInput; }
        word |= @as(u32, @intCast(byte)) << @intCast(index * 8);
    }
    return word;
}

fn writeWord(word: u32) !void {
    for (0..4) |index| {
        if (putchar(@intCast((word >> @intCast(index * 8)) & 255)) < 0) { return error.WriteFailed; }
    }
}

const EventRecord = extern struct {
    key: u32 = 0,
    phase: u32 = 0,
    physical: u32 = 0,
};

const ResultRecord = extern struct {
    outcome: u32 = 0,
    action: u32 = 0,
    repeated: u32 = 0,
    held_count: u32 = 0,
    has_current: u32 = 0,
    prefix_pending: u32 = 0,
    deadline_present: u32 = 0,
    deadline_low: u32 = 0,
    deadline_high: u32 = 0,
    overflow_low: u32 = 0,
    overflow_high: u32 = 0,
    repeat_action: u32 = 0,
    wants_binding: u32 = 0,
    current: EventRecord = .{},
    held: [5]EventRecord = @splat(.{}),
};

fn eventRecord(key: original.Key) EventRecord {
    var result: EventRecord = .{};
    for (keys, 0..) |known, index| {
        if (original.keybind.keyOrder(known, key) == .eq) {
            result.key = @intCast(index);
            break;
        }
    }

    result.phase = @intFromEnum(key.phase);
    result.physical = if (key.physical) |identity| identity.value else 0;

    return result;
}

fn emit(decision: Router.Decision, router: *const Router, key: original.Key) !void {
    const word_bits = 32;
    var result: ResultRecord = .{};
    result.outcome = switch (decision) { .forward => 0, .replay => 1, .action => 2, .pending => 3, .discard => 4 };
    switch (decision) {
        .forward => |value| result.current = eventRecord(value),
        .action => |request| {
            result.action = request.value;
            result.repeated = @intFromBool(request.repeated);
            result.current = eventRecord(request.key);
        },
        .replay => |replay| {
            result.held_count = replay.held_key_len;
            result.has_current = @intFromBool(replay.current_key != null);
            if (replay.current_key) |value| { result.current = eventRecord(value); }
            for (replay.held_keys[0..replay.held_key_len], 0..) |value, index| {
                result.held[index] = eventRecord(value);
            }
        },
        else => {},
    }

    result.prefix_pending = @intFromBool(router.prefixPending());
    const due = router.bindingDeadline();
    result.deadline_present = @intFromBool(due != null);
    result.deadline_low = @truncate(due orelse 0);
    result.deadline_high = @truncate((due orelse 0) >> word_bits);
    result.overflow_low = @truncate(router.leaseOverflowCount());
    result.overflow_high = @truncate(router.leaseOverflowCount() >> word_bits);
    result.repeat_action = router.repeatAction() orelse 0;
    result.wants_binding = @intFromBool(router.wantsBinding(key));
    const record_words = @sizeOf(ResultRecord) / @sizeOf(u32);
    const words: [record_words]u32 = @bitCast(result);
    for (words) |word| { try writeWord(word); }
}

pub fn main() !void {
    var router = try makeRouter(false);
    while (try readWord()) |operation| {
        var record: [10]u32 = @splat(0);
        record[0] = operation;
        for (record[1..]) |*word| { word.* = try readWord() orelse return error.TruncatedRecord; }
        if (record[1] >= keys.len or record[2] > 2) { return error.InvalidRecord; }
        var key = keys[record[1]];
        key.phase = @enumFromInt(record[2] + 1);
        key.physical = if (record[3] == 0) null else .{ .value = record[3] };
        const now = record[4] | (@as(u64, record[5]) << 32);
        var decision: Router.Decision = .discard;
        switch (operation) {
            0 => router = try makeRouter(false),
            1 => decision = router.routeEvent(.{ .key = key, .now_ns = now }, .{ .captures_keys = record[6] != 0, .repeat_policy = policy(router.repeatAction() orelse 0, record[7]) }),
            2 => decision = router.expireBinding(now),
            3 => decision = router.interrupt(),
            4 => router.cancelSequence(),
            5 => router.clear(),
            6 => {
                var replacement = try makeRouter(record[8] != 0);
                replacement.inheritPhysicalLeases(&router);
                router = replacement;
            },
            7 => router.eventFailed(key),
            8 => router.relinquishKey(.{ .value = record[3] }),
            else => return error.InvalidOperation,
        }
        if (decision == .action) { router.actionCompleted(decision.action, policy(decision.action.value, record[7])); }
        try emit(decision, &router, key);
    }
}
"""


def record(operation, key=0, phase=0, physical=0, now=0, captures=False, owner=1, empty=False):
    word_mask = (1 << 32) - 1
    return (operation, key, phase, physical, now & word_mask, now >> 32, int(captures), owner, int(empty), 0)


def corpus(random_cases):
    records = []
    for first, second, phase, captures in itertools.product(range(len(key_names)), range(len(key_names)), range(3), (False, True)):
        records.extend((record(0), record(1, first, physical=1), record(1, second, phase, 1 if phase else 2, 100, captures)))
    for sequence, _ in bindings:
        records.append(record(0))
        for physical, key in enumerate(sequence, 1):
            records.append(record(1, key, physical=physical))
        records.extend((record(1, sequence[-1], 1, len(sequence), 100), record(6, empty=True), record(1, sequence[-1], 2, len(sequence), 200)))
    records.append(record(0))
    records.extend(record(1, 3, physical=identity) for identity in range(1, 67))
    records.extend((record(5), record(1, 2, physical=1, now=(1 << 64) - 10), record(2, now=(1 << 64) - 1)))
    generator = random.Random(0x74656C6172)
    operations = [1] * 20 + list(range(9))
    now = 0
    for _ in range(random_cases):
        now = max(0, now + generator.randrange(-100, 1000))
        records.append(record(generator.choice(operations), generator.randrange(len(key_names)), generator.randrange(3), generator.randrange(71), now, generator.randrange(5) == 0, generator.randrange(4), generator.randrange(2) == 0))
    return records


def main():
    parser = argparse.ArgumentParser(description="Compare the C++ key router against lib/keyinput/GenericRouter.zig")
    parser.add_argument("--compiler", default=os.environ.get("CXX", "clang++"))
    parser.add_argument("--zig", default="zig")
    parser.add_argument("--random-cases", type=int, default=25000)
    arguments = parser.parse_args()
    if arguments.random_cases < 0:
        parser.error("--random-cases must be nonnegative")
    service = Path(__file__).resolve().parents[1]
    repository = service.parents[1]
    cpp = cpp_probe.replace("@key_count@", str(len(key_names))).replace("@names@", ",".join(json.dumps(name, ensure_ascii=False) for name in key_names))
    cpp = cpp.replace("@bindings@", ",".join(f"binding({{{','.join(map(str, sequence))}}},{action})" for sequence, action in bindings))
    zig = zig_probe.replace("@names@", ",".join(json.dumps(name, ensure_ascii=False) for name in key_names))
    zig = zig.replace("@bindings@", ",".join(f"try Binding.init(&.{{{','.join(f'keys[{key}]' for key in sequence)}}},{action})" for sequence, action in bindings))
    records = corpus(arguments.random_cases)
    request = b"".join(struct.pack(f"<{record_words}I", *entry) for entry in records)
    with tempfile.TemporaryDirectory(prefix="telar-key-router-") as directory:
        temporary = Path(directory)
        cpp_source, zig_source = temporary / "probe.cpp", temporary / "probe.zig"
        cpp_binary, zig_binary = temporary / "cpp_probe", temporary / "zig_probe"
        cpp_source.write_text(cpp)
        zig_source.write_text(zig)
        subprocess.run([arguments.compiler, "-std=c++23", "-O2", f"-I{service}", f"-I{repository / 'services/runtime-cpp'}", f"-I{repository / 'dlls/telar-client/include'}", str(cpp_source), "-o", str(cpp_binary)], check=True)
        subprocess.run([arguments.zig, "build-exe", "-O", "ReleaseFast", "-lc", "--dep", "keyinput", f"-Mroot={zig_source}", f"-Mkeyinput={repository / 'lib/keyinput/root.zig'}", f"-femit-bin={zig_binary}"], check=True)
        reference = subprocess.run([str(zig_binary)], input=request, stdout=subprocess.PIPE, check=True).stdout
        candidate = subprocess.run([str(cpp_binary)], input=request, stdout=subprocess.PIPE, check=True).stdout
    if len(reference) != len(records) * result_bytes or len(candidate) != len(reference):
        raise SystemExit("Unexpected probe result length")
    for index, entry in enumerate(records):
        start = index * result_bytes
        expected = reference[start:start + result_bytes]
        actual = candidate[start:start + result_bytes]
        if expected != actual:
            raise SystemExit(f"Record {index}, request {entry}: Zig {struct.unpack(f'<{result_words}I', expected)}, C++ {struct.unpack(f'<{result_words}I', actual)}")
    print(f"Matched {len(records)} transitions byte-for-byte against lib/keyinput/GenericRouter.zig")


if __name__ == "__main__":
    main()
