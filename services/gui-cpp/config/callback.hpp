#pragma once

#include "input/action.hpp"
#include "input/binding.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_config/callback_context.hpp"
#include <array>
#include <cstddef>
#include <cstdint>

namespace telar::gui {

using BindingContext = runtime::config::BindingContext;

struct BindingEffects {
  static constexpr std::size_t maximum_effects = 16;
  std::array<BindingAction, maximum_effects> actions{};
  std::size_t length = 0;
  std::size_t dropped = 0;
};

struct InputExpression {
  enum class Kind : std::uint8_t {
    consume,
    forward,
    keys,
    paste,
  };

  static constexpr std::size_t maximum_keys = 16;
  static constexpr std::size_t maximum_paste_bytes = 4096;
  Kind kind = Kind::consume;
  std::array<KeyChord, maximum_keys> keys{};
  std::size_t length = 0;
  runtime::FixedText<maximum_paste_bytes> paste;
};

}
