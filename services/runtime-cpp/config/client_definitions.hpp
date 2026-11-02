#pragma once

#include "../lua/value.hpp"
#include "named_definitions_validator.hpp"
#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>

namespace telar::runtime::config {

class ClientDefinitions {
public:
  explicit ClientDefinitions(const lua::Value &client, const lua::Value *inherited = nullptr)
      : client_(client),
        inherited_(inherited) {}

  bool contains(const char *section, std::string_view name) const {
    return index(section, name).has_value();
  }

  std::optional<std::uint8_t> index(const char *section, std::string_view name) const {
    if (client_.present()) {
      const auto definitions = client_.field(section);
      if (definitions.present()) {
        return indexOf(definitions, name);
      }
    }
    if (inherited_ != nullptr && inherited_->present()) {
      return indexOf(inherited_->field(section), name);
    }
    return std::nullopt;
  }

private:
  static std::optional<std::uint8_t> indexOf(const lua::Value &definitions, std::string_view name) {
    if (!definitions.present()) {
      return std::nullopt;
    }

    bool found = false;
    std::size_t preceding = 0;
    definitions.eachField([&](std::string_view candidate, const lua::Value &) {
      found |= candidate == name;
      preceding += candidate < name;
    });
    if (!found) {
      return std::nullopt;
    }
    return preceding < NamedDefinitionsValidator::maximum_definitions ? static_cast<std::uint8_t>(preceding) : std::numeric_limits<std::uint8_t>::max();
  }

  const lua::Value &client_;
  const lua::Value *inherited_;
};

}
