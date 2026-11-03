#pragma once

#include "edit.hpp"
#include "failure.hpp"
#include "limits.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include <optional>
#include <string_view>

namespace telar::gui {

class OwnedMachineEdit {
public:
  [[nodiscard]] static OwnedMachineEdit copy(const MachineEdit &edit) {
    if (edit.label.size() > MachineLimits::label_bytes || edit.value.size() > MachineLimits::destination_bytes) {
      throw MachineFailure{MachineError::invalid_label};
    }

    if (edit.color && edit.color->size() > MachineLimits::color_bytes) {
      throw MachineFailure{MachineError::invalid_color};
    }

    OwnedMachineEdit result;
    result.kind_ = edit.kind;
    result.enabled_ = edit.enabled;
    result.login_agent_ = edit.login_agent;
    result.login_ = edit.login;
    result.has_color_ = edit.color.has_value();
    result.label_.assign(edit.label);
    result.value_.assign(edit.value);
    if (edit.color) {
      result.color_.assign(*edit.color);
    }

    return result;
  }

  [[nodiscard]] MachineEdit view() const noexcept {
    return {
        .kind = kind_,
        .label = label_.view(),
        .value = value_.view(),
        .color = has_color_ ? std::optional{color_.view()} : std::nullopt,
        .enabled = enabled_,
        .login_agent = login_agent_,
        .login = login_,
    };
  }

private:
  OwnedMachineEdit() = default;

  MachineEditKind kind_ = MachineEditKind::add;
  MachineAgent login_agent_ = MachineAgent::claude;
  MachineLogin login_ = MachineLogin::pending;
  bool enabled_ = true;
  bool has_color_ = false;
  runtime::FixedText<MachineLimits::label_bytes> label_;
  runtime::FixedText<MachineLimits::destination_bytes> value_;
  runtime::FixedText<MachineLimits::color_bytes> color_;
};

}
