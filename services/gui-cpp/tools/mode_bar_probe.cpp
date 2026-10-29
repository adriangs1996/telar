#include "core/geometry.hpp"
#include "core/theme_values.hpp"
#include "input/binding.hpp"
#include "input/key_character.hpp"
#include "presentation/mode_bar_layout.hpp"
#include "presentation/mode_hints.hpp"
#include <array>
#include <bit>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <exception>
#include <memory>
#include <stdexcept>
#include <string_view>

namespace {

using namespace telar::gui;

static_assert(std::endian::native == std::endian::little);

struct ChordRecord {
  std::uint32_t kind = 0;
  std::uint32_t character = 0;
  std::uint32_t modifiers = 0;
};

struct Request {
  Rect bounds;
  float ratio = 1;
  float cell_width = 1;
  std::uint32_t mode = 0;
  std::uint32_t mask = 0;
  std::array<ChordRecord, ModeHints::capacity> chords{};
};

constexpr std::size_t request_bytes = 128;
static_assert(sizeof(Request) == request_bytes);

template <typename Value>
void write(const Value &value) {
  if (std::fwrite(std::addressof(value), sizeof(Value), 1, stdout) != 1) {
    throw std::runtime_error{"ModeBarWriteFailed"};
  }
}

void writeText(std::string_view text) {
  write(static_cast<std::uint32_t>(text.size()));
  if (!text.empty() && std::fwrite(text.data(), sizeof(char), text.size(), stdout) != text.size()) {
    throw std::runtime_error{"ModeBarWriteFailed"};
  }
}

void measure(const Request &input) {
  if (input.mode > static_cast<std::uint32_t>(StatusMode::copy)) {
    throw std::invalid_argument{"InvalidModeBarRequest"};
  }

  ModeBarRequest request{.mode = static_cast<StatusMode>(input.mode), .bounds = input.bounds, .ratio = input.ratio, .cell_width = input.cell_width};
  for (std::size_t index = 0; index < input.chords.size(); ++index) {
    if ((input.mask & (std::uint32_t{1} << index)) == 0) {
      continue;
    }

    const auto &key = input.chords[index];
    if (key.kind > static_cast<std::uint32_t>(KeyChord::Key::back_tab)) {
      throw std::invalid_argument{"InvalidModeBarKey"};
    }

    request.hints.append({.key = {.key = static_cast<KeyChord::Key>(key.kind), .character = key.kind == 0 ? KeyCharacter::pack(key.character) : 0, .modifiers = key.modifiers}, .label = ModeHints::actions[index].second});
  }

  const auto layout = ModeBarLayout::measure(request);
  const auto chip = layout.chip();
  write(static_cast<std::uint32_t>(layout.labels().size()));
  write(std::array{chip.x, chip.y, chip.width, chip.height, chip.empty() ? 0.0F : ModeBarLayout::chip_radius * request.ratio});
  for (const auto &label : layout.labels()) {
    writeText(label.text.view());
    write(std::array{label.bounds.x, label.bounds.y, label.bounds.width, label.bounds.height});
    writeText(palette_names[static_cast<std::size_t>(label.ink)]);
    write(static_cast<std::uint8_t>(label.bold));
  }
}

}

int main() {
  try {
    Request request;
    while (true) {
      const auto bytes = std::fread(&request, 1, sizeof(request), stdin);
      if (bytes == 0 && std::feof(stdin) != 0) {
        break;
      }

      if (bytes != sizeof(request)) {
        throw std::runtime_error{"IncompleteModeBarRequest"};
      }

      measure(request);
    }

    return std::fflush(stdout) == 0 ? 0 : 1;
  } catch (const std::exception &error) {
    static_cast<void>(std::fputs(error.what(), stderr));

    return 1;
  }
}
