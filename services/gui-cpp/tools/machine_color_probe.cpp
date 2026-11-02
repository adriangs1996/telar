#include "core/color_name.hpp"
#include "core/theme_values.hpp"
#include "probe_io.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <exception>
#include <iostream>
#include <limits>
#include <span>
#include <string_view>
#include <variant>

namespace {

using namespace telar;
using namespace telar::gui;
using namespace telar::gui::probe;

enum class Result : std::uint8_t {
  invalid,
  inherited,
  rgb,
  role,
};

void color() {
  constexpr std::size_t capacity = static_cast<std::size_t>(std::numeric_limits<std::uint8_t>::max()) + 1;
  std::array<char, capacity> bytes{};
  const auto size = read<std::uint8_t>();
  for (auto &byte : std::span{bytes}.first(size)) {
    byte = static_cast<char>(read<std::uint8_t>());
  }

  std::array<Byte, 3> channels{};
  const auto parsed = ColorName::parse(std::string_view{bytes.data(), size});
  Result result = Result::invalid;
  if (parsed) {
    if (const auto *role = std::get_if<PaletteRole>(&*parsed)) {
      result = Result::role;
      channels.front() = static_cast<Byte>(*role);
    } else {
      const auto literal = std::get<CellColor>(*parsed);
      result = literal.kind == CellColor::Kind::default_color ? Result::inherited : Result::rgb;
      channels = literal.channels;
    }
  }

  write(result);
  for (const auto channel : channels) {
    write(channel);
  }
}

}

int main() {
  try {
    while (std::getchar() != EOF) {
      color();
    }
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
