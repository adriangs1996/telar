#include <cstdint>

import std;
import telar.base.text;
import telar.runtime.terminal.control;
import telar.testing;

namespace {

  using telar::testing::check;

  using namespace telar::runtime;
  using namespace telar::runtime::control;

  std::string encode(std::span<const std::uint8_t> bytes) {
    std::string encoded((bytes.size() + 2) / 3 * 4, '\0');

    check(base64::encode(bytes, encoded) == encoded.size());
    return encoded;
  }

  bool decodes(std::string_view encoded, std::span<const std::uint8_t> expected) {
    std::vector<std::uint8_t> output(expected.size() + 64);
    const auto written = decodeGraphicsPayload(encoded, output);

    return written && std::ranges::equal(std::span{output}.first(*written), expected);
  }

  bool rejected(std::string_view encoded, std::size_t capacity) {
    // The decoder may write only the span it is given: the guard bytes after it stay put.
    std::vector<std::uint8_t> output(capacity + 64, 0xa5);
    const auto written = decodeGraphicsPayload(encoded, std::span{output}.first(capacity));

    return !written && std::ranges::all_of(std::span{output}.subspan(capacity), [](std::uint8_t byte) {
      return byte == 0xa5;
    });
  }

  // A pane's graphics payload decodes to its bytes with or without whitespace, and any
  // malformed payload, wherever the fault sits, decodes to nothing.
  void malformedRejected() {
    std::vector<std::uint8_t> pixels(100);

    for (std::size_t index = 0; index < pixels.size(); ++index) {
      pixels[index] = static_cast<std::uint8_t>(index * 37 + 11);
    }

    const auto clean = encode(pixels);

    check(clean.ends_with("==") && decodes(clean, pixels));

    std::string spaced;

    for (std::size_t index = 0; index < clean.size(); ++index) {
      spaced.push_back(clean[index]);
      spaced.append(index % 3 == 0 ? " \n" : index % 5 == 0 ? "\t\r\f"
                                                            : "");
    }

    check(decodes(spaced, pixels));

    for (std::size_t offset = 0; offset < 64; ++offset) {
      auto invalid = clean;

      invalid[offset] = '*';
      check(rejected(invalid, pixels.size() + 64));
    }

    check(rejected("Q=QQ", 64));
    check(rejected("QUJD"
                   "QQ=="
                   "QUJD",
        64));
    check(rejected("QUJDQ", 64));
    check(rejected("QUJD", 2));
    check(rejected(clean, pixels.size() - 1));
  }

  const telar::testing::Case case_malformed_rejected{"graphics_payload.malformed_rejected", malformedRejected};

}
