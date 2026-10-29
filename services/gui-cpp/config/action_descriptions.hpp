#pragma once

#include "core/memory.hpp"
#include "input/binding.hpp"
#include "memory/fixed_text.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <variant>

namespace telar::gui {

struct NotificationActionDescription {
  runtime::FixedText<max_notification_title_bytes> title;
  runtime::FixedText<max_notification_message_bytes> message;
  NotificationLevel level = NotificationLevel::info;
  std::uint32_t duration_ms = default_notification_duration_ms;
  NotificationTarget target;
};

struct DefinitionActionDescription {
  enum class Kind : std::uint8_t {
    panel,
    pick,
  };
  Kind kind = Kind::panel;
  std::uint8_t index = 0;
};

struct PluginActionDescription {
  std::uint64_t plugin = 0;
  std::uint64_t action = 0;
};

using ExtendedActionDescription = std::variant<NotificationActionDescription, DefinitionActionDescription, PluginActionDescription>;

template <Allocator Memory>
class ActionDescriptions {
public:
  explicit ActionDescriptions(Memory &memory)
      : extended_(AllocatorRef<ExtendedActionDescription, Memory>{memory}) {}

  void replaceBindings() noexcept {
    extended_.clear();
  }

  [[nodiscard]] const ExtendedActionDescription &at(std::int32_t index) const {
    if (index < 0 || static_cast<std::size_t>(index) >= extended_.size()) {
      throw std::runtime_error{"BindingNotFound"};
    }

    return extended_[static_cast<std::size_t>(index)];
  }

  std::int32_t retain(const ExtendedActionDescription &description) {
    if (extended_.size() == BindingLimits::bindings) {
      throw std::length_error{"Too many configured actions"};
    }

    const auto index = extended_.size();
    extended_.push_back(description);

    return static_cast<std::int32_t>(index);
  }

  std::int32_t registerCallback() {
    if (callbacks_ == maximum_callbacks) {
      throw std::length_error{"Too many Lua callbacks"};
    }

    return static_cast<std::int32_t>(callbacks_++);
  }

private:
  static constexpr std::size_t compiled_client_sections = 2;
  static constexpr std::size_t maximum_callbacks = compiled_client_sections * BindingLimits::bindings;

  Vector<ExtendedActionDescription, Memory> extended_;
  std::size_t callbacks_ = 0;
};

}
