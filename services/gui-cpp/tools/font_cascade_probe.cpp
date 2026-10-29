#include "core/geometry.hpp"
#include "core/memory.hpp"
#include "fonts/font_role.hpp"
#include "fonts/font_runs.hpp"
#include "fonts/glyph_transform.hpp"
#include "fonts/text_layout.hpp"
#include "probe_io.hpp"
#include "probe_text.hpp"
#include "tests/font_fixture.hpp"
#include "text/text_fit.hpp"
#include <array>
#include <bit>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <exception>
#include <filesystem>
#include <limits>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>
#include <utility>

namespace {

using namespace telar::gui;
using namespace telar::gui::fonts;

enum class Request : std::uint8_t {
  text,
  transform,
};

struct TextInput {
  std::uint32_t preferred = 0;
  std::uint32_t height = 0;
  float width = 0;
};

static_assert(sizeof(TextInput) == sizeof(std::uint32_t) * 3);
static_assert(std::endian::native == std::endian::little);

std::optional<Request> nextRequest() {
  std::uint32_t kind = 0;
  const auto count = std::fread(&kind, sizeof(char), sizeof(kind), stdin);
  if (count == 0 && std::feof(stdin) != 0) {
    return std::nullopt;
  }

  if (count != sizeof(kind)) {
    throw std::runtime_error{"IncompleteCascadeProbeRequest"};
  }

  if (kind > std::to_underlying(Request::transform)) {
    throw std::invalid_argument{"UnknownCascadeProbeRequest"};
  }

  return static_cast<Request>(kind);
}

void textCase(test::FontFixture<SystemAllocator> &fonts, SystemAllocator &memory) {
  const auto input = probe::read<TextInput>();
  if (input.preferred > std::to_underlying(FontRole::symbols) || input.height == 0 || input.height > std::numeric_limits<std::uint16_t>::max()) {
    throw std::invalid_argument{"InvalidCascadeProbeRequest"};
  }

  const auto text = probe::readText(memory);
  const TextRequest request{.pixel_height = static_cast<std::uint16_t>(input.height), .preferred = static_cast<FontRole>(input.preferred)};
  TextLayout<SystemAllocator> layout{memory};
  TextFit::Buffer buffer{};
  try {
    layout.shape(fonts, text, request);
    const auto measure = [&](std::string_view label) {
      return static_cast<float>(TextLayout<SystemAllocator>::measure(fonts, label, request));
    };
    const auto fitted = TextFit::fit(text, input.width, measure, buffer);
    probe::write(std::uint32_t{1});
    probe::write(static_cast<float>(layout.advance()));
    probe::writeText(fitted);
    FontRuns runs{fonts, text, request.preferred};
    while (const auto span = runs.next()) {
      const auto role = span->role.value_or(FontRole::primary);
      probe::writeText(span->text);
      probe::write(static_cast<std::uint32_t>(role));
      probe::write(fittedFont(role) ? span->columns : 0);
    }

    probe::writeText({});
  } catch (const std::invalid_argument &) {
    probe::write(std::uint32_t{2});
  }
}

void transformCase() {
  const auto ink = probe::read<Rect>();
  const auto cell = probe::read<Rect>();
  const auto transform = GlyphTransform::fit(ink, cell);
  probe::write(std::array{transform.x, transform.y, transform.scale});
}

}

int main(int argc, char **argv) {
  const auto arguments = std::span{argv, static_cast<std::size_t>(argc)};
  constexpr std::size_t expected_arguments = 3;
  if (arguments.size() != expected_arguments) {
    return 1;
  }

  try {
    SystemAllocator memory;
    test::FontFixture fonts{memory, std::filesystem::path{arguments[1]}, arguments[2]};
    while (const auto kind = nextRequest()) {
      switch (*kind) {
      case Request::text:
        textCase(fonts, memory);
        break;
      case Request::transform:
        transformCase();
        break;
      default:
        throw std::invalid_argument{"UnknownCascadeProbeRequest"};
      }
    }

    return std::fflush(stdout) == 0 ? 0 : 1;
  } catch (const std::exception &error) {
    static_cast<void>(std::fputs(error.what(), stderr));
    return 1;
  }
}
