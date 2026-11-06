#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "../attachments/types.hpp"
#include <cstdint>
#include <optional>
#include <stdexcept>
#include <array>
#include <cstddef>
#include <exception>
#include <iostream>
#include <limits>

#include "attachments/types.hpp"


import telar.gui.attachments.marker_input;

namespace {

using namespace telar::gui;

enum class Operation : std::uint8_t { reserve, finish_random, cancel_random, finish_current, cancel_current, restart, reserve_invalid, count };
enum class Outcome : std::uint8_t { none, reserved, busy, finished, stale, cancelled, unchanged, invalid, exhausted };

constexpr std::uint64_t seed = 0x9e3779b97f4a7c15;
constexpr std::uint64_t operations = 65536;
constexpr std::uint64_t pane_domain = 5;
constexpr std::uint64_t generation_domain = 5;
constexpr std::uint64_t completion_domain = 17;
constexpr unsigned first_shift = 13;
constexpr unsigned second_shift = 7;
constexpr unsigned third_shift = 17;
constexpr unsigned pane_shift = 8;
constexpr unsigned generation_shift = 16;
constexpr unsigned completion_shift = 32;

std::uint64_t randomWord(std::uint64_t &state) {
  state ^= state << first_shift;
  state ^= state >> second_shift;
  state ^= state << third_shift;

  return state;
}

void write(std::uint64_t value) {
  std::array<char, sizeof(value)> bytes{};
  for (std::size_t index = 0; index < bytes.size(); ++index) {
    bytes[index] = static_cast<char>((value >> (index * std::numeric_limits<unsigned char>::digits)) & std::numeric_limits<unsigned char>::max());
  }

  std::cout.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
}

Outcome execute(ClipboardCaptureState &state, Operation operation, AttachmentTarget &target, std::uint64_t &id, std::optional<ClipboardCapture> &result) {
  try {
    switch (operation) {
    case Operation::reserve_invalid:
      target = {};
      [[fallthrough]];
    case Operation::reserve:
      result = state.reserve(target);
      return result ? Outcome::reserved : Outcome::busy;
    case Operation::finish_current:
      id = state.current() ? state.current()->id : ClipboardCapture::invalid_id;
      [[fallthrough]];
    case Operation::finish_random:
      result = state.finish(id);
      return result ? Outcome::finished : Outcome::stale;
    case Operation::cancel_current:
      target = state.current() ? state.current()->target : AttachmentTarget{};
      [[fallthrough]];
    case Operation::cancel_random:
      return state.cancel(target) ? Outcome::cancelled : Outcome::unchanged;
    case Operation::restart:
      state = ClipboardCaptureState{id};
      return Outcome::none;
    case Operation::count:
      throw std::logic_error{"InvalidOperation"};
    }
  } catch (const std::invalid_argument &) {
    return Outcome::invalid;
  } catch (const std::overflow_error &) {
    return Outcome::exhausted;
  }

  throw std::logic_error{"InvalidOperation"};
}

}

int main() try {
  ClipboardCaptureState state;
  auto random = seed;
  for (std::uint64_t index = 0; index < operations; ++index) {
    const auto word = randomWord(random);
    const auto operation = static_cast<Operation>(word % static_cast<std::uint64_t>(Operation::count));
    AttachmentTarget target{.pane_id = (word >> pane_shift) % pane_domain, .pane_generation = (word >> generation_shift) % generation_domain};
    auto id = (word >> completion_shift) % completion_domain;
    if (operation == Operation::restart) {
      id = (word & ClipboardCapture::first_id) != 0 ? std::numeric_limits<std::uint64_t>::max() : ClipboardCapture::first_id;
    }

    std::optional<ClipboardCapture> result;
    const auto outcome = execute(state, operation, target, id, result);

    const auto returned = result.value_or(ClipboardCapture{});
    const auto current = state.current().value_or(ClipboardCapture{});
    for (const auto value : std::array{index, static_cast<std::uint64_t>(operation), target.pane_id, target.pane_generation, id, static_cast<std::uint64_t>(outcome), returned.id, returned.target.pane_id, returned.target.pane_generation, current.id, current.target.pane_id, current.target.pane_generation, state.nextId()}) {
      write(value);
    }
  }

  return std::cout.good() ? 0 : 1;
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
