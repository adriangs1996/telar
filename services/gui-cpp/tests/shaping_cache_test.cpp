#include "assertions.hpp"
#include "core/memory.hpp"
#include "fonts/face.hpp"
#include "fonts/shaped_run_view.hpp"
#include "platform/font.h"
#include "platform/read_file.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <filesystem>
#include <iostream>
#include <new>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace {

using namespace telar::gui;
using namespace telar::gui::fonts;
using telar::gui::test::require;

constexpr std::array<std::uint16_t, 4> heights{15, 19, 26, 39};

struct OptionalAllocationFailures {
  bool enabled = false;
  std::size_t attempts = 0;
};

OptionalAllocationFailures &optionalAllocationFailures() {
  static OptionalAllocationFailures state;
  return state;
}

class FailOptionalAllocations {
public:
  FailOptionalAllocations() noexcept {
    optionalAllocationFailures().enabled = true;
  }

  ~FailOptionalAllocations() {
    optionalAllocationFailures().enabled = false;
  }

  FailOptionalAllocations(const FailOptionalAllocations &) = delete;
  FailOptionalAllocations &operator=(const FailOptionalAllocations &) = delete;
  FailOptionalAllocations(FailOptionalAllocations &&) = delete;
  FailOptionalAllocations &operator=(FailOptionalAllocations &&) = delete;
};

struct Snapshot {
  std::vector<ShapedGlyph> glyphs;
  std::int32_t advance;
  bool right_to_left;

  bool operator==(const Snapshot &) const = default;
};

Snapshot capture(ShapedRunView run) {
  Snapshot result{.glyphs = {}, .advance = run.advance(), .right_to_left = run.rightToLeft()};
  result.glyphs.reserve(run.size());
  for (std::size_t index = 0; index < run.size(); ++index) {
    result.glyphs.push_back(run.glyph(index));
  }

  return result;
}

Snapshot fresh(std::span<const std::uint8_t> bytes, std::string_view text, std::uint16_t height) {
  Face reference{bytes};
  return capture(reference.shape(text, height));
}

void warmResultsMatchFreshFaces(std::span<const std::uint8_t> bytes) {
  Face retained{bytes};
  const std::vector<std::string> texts{"", "W", "== -> <= !=", "e\xcc\x81", "caf\xc3\xa9", "\xd7\xa9\xd7\x9c\xd7\x95\xd7\x9d", "\xf0\x9f\x98\x80", std::string(64, 'W'), std::string(65, 'W'), std::string(256, 'W')};
  for (const auto &text : texts) {
    for (const auto height : heights) {
      const auto expected = fresh(bytes, text, height);
      require(capture(retained.shape(text, height)) == expected, "first shaping must match an independent fresh face");
      static_cast<void>(retained.metrics(heights.back()));
      require(capture(retained.shape(text, height)) == expected, "reused glyphs must retain the requested height, clusters, positions and direction");
    }
  }

  constexpr std::size_t distinct_labels = 1024;
  for (std::size_t index = 0; index < distinct_labels; ++index) {
    const auto text = "terminal " + std::to_string(index) + " -> != [ready]";
    const auto height = heights[index % heights.size()];
    const auto expected = fresh(bytes, text, height);
    require(capture(retained.shape(text, height)) == expected, "entry replacement must preserve exact shaping");
    require(capture(retained.shape(text, height)) == expected, "a repeated replacement must preserve exact shaping");
  }

  for (const auto height : heights) {
    require(capture(retained.shape("terminal 0 -> != [ready]", height)) == fresh(bytes, "terminal 0 -> != [ready]", height), "returning to an evicted label must not expose another entry");
  }
}

void phaseChangesPreserveShaping(std::span<const std::uint8_t> bytes) {
  Face retained{bytes};
  constexpr std::size_t unique_requests = 1024;
  for (std::size_t index = 0; index < unique_requests; ++index) {
    const auto text = "unique " + std::to_string(index) + " -> !=";
    const auto height = heights[index % heights.size()];
    require(capture(retained.shape(text, height)) == fresh(bytes, text, height), "skipping ineffective lookups must preserve unique text shaping");
  }

  constexpr std::size_t repeated_requests = 256;
  constexpr std::size_t repeated_labels = 8;
  for (std::size_t index = 0; index < repeated_requests; ++index) {
    const auto text = "recovery " + std::to_string(index % repeated_labels) + " -> !=";
    const auto height = heights[(index / repeated_labels) % heights.size()];
    require(capture(retained.shape(text, height)) == fresh(bytes, text, height), "resuming effective lookups must preserve text and height");
  }
}

void optionalAllocationFailurePreservesShaping(std::span<const std::uint8_t> bytes) {
  Face retained{bytes};
  const auto before = optionalAllocationFailures().attempts;
  for (const auto height : heights) {
    const auto expected = fresh(bytes, "== -> <= !=", height);
    const FailOptionalAllocations failure;
    require(capture(retained.shape("== -> <= !=", height)) == expected, "optional cache allocation failure must leave ordinary shaping available");
  }

  require(optionalAllocationFailures().attempts == before + 1, "an unavailable optional cache must not retry allocation on every shaping request");
}

void invalidRequestsRemainRejected(std::span<const std::uint8_t> bytes) {
  Face retained{bytes};
  static_cast<void>(retained.shape("W", heights.front()));
  bool invalid_utf8 = false;
  try {
    static_cast<void>(retained.shape("\xff", heights.front()));
  } catch (const telar::EncodingError &) {
    invalid_utf8 = true;
  }

  bool invalid_height = false;
  try {
    static_cast<void>(retained.shape("W", 0));
  } catch (const std::invalid_argument &) {
    invalid_height = true;
  }

  require(invalid_utf8 && invalid_height, "a populated cache must not bypass invalid request rejection");
}

}

void *operator new(std::size_t bytes, [[maybe_unused]] const std::nothrow_t &tag) noexcept { // NOLINT(readability-inconsistent-declaration-parameter-name)
  if (optionalAllocationFailures().enabled) {
    ++optionalAllocationFailures().attempts;
    return nullptr;
  }

  try {
    return ::operator new(bytes);
  } catch (const std::bad_alloc &) {
    return nullptr;
  }
}

int main(int argc, char **argv) {
  const auto arguments = std::span{argv, static_cast<std::size_t>(argc)};
  constexpr std::size_t expected_arguments = 2;
  if (arguments.size() != expected_arguments) {
    return 1;
  }

  try {
    SystemAllocator memory;
    const std::filesystem::path assets{arguments[1]};
    for (const auto *name : {"JetBrainsMono-Regular.ttf", "IBMPlexSans-Regular.ttf", "SymbolsNerdFontMono-Regular.ttf"}) {
      const auto path = assets / name;
      const auto data = telar::runtime::readFile(memory, path.c_str(), telar_font_max_bytes);
      const Vector<std::uint8_t, SystemAllocator> bytes{data.cbegin(), data.cend(), AllocatorRef<std::uint8_t, SystemAllocator>{memory}};
      warmResultsMatchFreshFaces(bytes);
      phaseChangesPreserveShaping(bytes);
      optionalAllocationFailurePreservesShaping(bytes);
      invalidRequestsRemainRejected(bytes);
    }
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
