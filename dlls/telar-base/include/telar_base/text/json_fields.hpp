#pragma once

#include "telar_base/text/json.hpp"
#include <array>
#include <stdexcept>

namespace telar::runtime {

template <Allocator Memory, std::size_t Count>
class JsonFields {
public:
  explicit JsonFields(Memory &memory, const JsonValue &object, const std::array<std::string_view, Count> &names)
      : names_(names), text_(AllocatorRef<char, Memory>{memory}) {
    object.eachMember([&](const JsonValue &key, const JsonValue &value) {
      key.string(text_);
      const auto index = position(text_);
      if (values_[index]) {
        throw std::invalid_argument{"Duplicate JSON field"};
      }
      values_[index] = value;
    });
  }

  const std::optional<JsonValue> &optional(std::string_view name) const {
    return values_[position(name)];
  }

  const JsonValue &required(std::string_view name) const {
    const auto &value = optional(name);
    if (!value) {
      throw std::invalid_argument{"Missing JSON field"};
    }
    return *value;
  }

  std::string_view string(std::string_view name) {
    required(name).string(text_);
    return text_;
  }

private:
  std::size_t position(std::string_view name) const {
    const auto found = std::ranges::find(names_, name);
    if (found == names_.end()) {
      throw std::invalid_argument{"Unknown JSON field"};
    }
    return static_cast<std::size_t>(found - names_.begin());
  }

  std::array<std::string_view, Count> names_;
  std::array<std::optional<JsonValue>, Count> values_;
  String<Memory> text_;
};

template <Allocator Memory, std::size_t Count>
JsonFields(Memory &memory, const JsonValue &object, const std::array<std::string_view, Count> &names) -> JsonFields<Memory, Count>;

}
