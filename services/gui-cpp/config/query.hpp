#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <string_view>
#include <utility>

namespace telar::gui {

struct ConfigurationQuery {
  static constexpr std::size_t capacity = 4096;

  enum class Section : std::uint8_t {
    client,
    theme,
    gui,
    input,
    runtime,
    binding,
  };

  Section section = Section::client;
  std::int64_t index = 0;

  static constexpr auto sections = std::to_array<std::pair<std::string_view, Section>>({
      {"client", Section::client},
      {"theme", Section::theme},
      {"gui", Section::gui},
      {"input", Section::input},
      {"runtime", Section::runtime},
      {"binding", Section::binding},
  });

  [[nodiscard]] static ConfigurationQuery parse(std::string_view name, std::int64_t index) {
    if (name.empty()) {
      return {.section = Section::client, .index = index};
    }

    for (const auto &[known, section] : sections) {
      if (name == known) {
        return {.section = section, .index = index};
      }
    }

    throw std::invalid_argument{"UnknownConfigurationSection"};
  }
};

}
