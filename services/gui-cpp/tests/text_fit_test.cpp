#include "text/grapheme_cursor.hpp"
#include "text/text_fit.hpp"
#include <array>
#include <cstddef>
#include <cstdio>
#include <exception>
#include <limits>
#include <stdexcept>
#include <string_view>

namespace {

using namespace telar::gui;

void require(bool condition, const char *message) {
  if (!condition) {
    throw std::runtime_error{message};
  }
}

template <typename Operation>
void rejects(Operation operation) {
  try {
    operation();
  } catch (const std::invalid_argument &) {
    return;
  }

  throw std::runtime_error{"Nonfinite geometry or measurements must be rejected"};
}

void borrowedAndBoundedOutput() {
  TextFit::Buffer buffer{};
  constexpr std::string_view label = "label";
  std::size_t calls = 0;
  const auto measure = [&](std::string_view text) {
    ++calls;

    return static_cast<float>(text.size());
  };
  const auto full = TextFit::fit(label, static_cast<float>(label.size()), measure, buffer);
  require(full.data() == label.data() && full == label && calls == 1, "Fitting text must borrow its source after one measurement");
  require(TextFit::fit(label, 1, measure, buffer).empty(), "A width smaller than the ellipsis must produce no text");

  constexpr std::size_t input_bytes = 4096;
  std::array<char, input_bytes> long_label{};
  long_label.fill('i');
  constexpr float wide_truncation = 3000;
  const auto fitted = TextFit::fit({long_label.data(), long_label.size()}, wide_truncation, measure, buffer);
  require(fitted.data() == buffer.data() && fitted.size() == buffer.size() && fitted.ends_with(TextFit::ellipsis), "Truncation must respect the caller's fixed-capacity output");
}

void graphemesRemainWhole() {
  TextFit::Buffer buffer{};
  const auto measure = [](std::string_view text) {
    GraphemeCursor cursor{text};
    std::size_t count = 0;
    while (cursor.next()) {
      ++count;
    }

    return static_cast<float>(count);
  };
  constexpr float two_clusters = 2.2F;
  require(TextFit::fit("ábc", two_clusters, measure, buffer) == "á…", "A combining cluster must stay attached to its base before the ellipsis");
}

void invalidMeasurements() {
  TextFit::Buffer buffer{};
  const auto measure = [](std::string_view text) {
    return static_cast<float>(text.size());
  };
  constexpr auto nonfinite = std::numeric_limits<float>::quiet_NaN();
  rejects([&] {
    static_cast<void>(TextFit::fit("label", nonfinite, measure, buffer));
  });
  const auto invalid_measure = [](std::string_view) {
    return nonfinite;
  };
  rejects([&] {
    static_cast<void>(TextFit::fit("label", 1, invalid_measure, buffer));
  });
  const auto negative_measure = [](std::string_view) {
    return -1.0F;
  };
  rejects([&] {
    static_cast<void>(TextFit::fit("label", 1, negative_measure, buffer));
  });
}

}

int main() {
  try {
    borrowedAndBoundedOutput();
    graphemesRemainWhole();
    invalidMeasurements();

    return 0;
  } catch (const std::exception &error) {
    static_cast<void>(std::fputs(error.what(), stderr));

    return 1;
  }
}
