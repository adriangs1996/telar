module telar.gui.features.machines;

import std;

namespace telar::gui::features::machines {

  void MachineProfileEdits::add(MachineProfiles& profiles, const MachineEdit& edit, MachineId id) {
    profiles.add(MachineProfile::create(id, {
                                                .label = edit.label,
                                                .destination = edit.value,
                                                .color = edit.color,
                                                .enabled = edit.enabled,
                                            }));
  }

  void MachineProfileEdits::change(MachineProfiles& profiles, const MachineEdit& edit, std::string_view local_fallback) {
    switch (edit.kind) {
    case MachineEditKind::add:
      throw std::logic_error{"MachineAddNeedsIdentity"};
    case MachineEditKind::remove:
      profiles.remove(edit.label);
      break;
    case MachineEditKind::rename:
      requireRemoteLabel(profiles, edit.value, local_fallback);
      profiles.rename(edit.label, edit.value);
      break;
    case MachineEditKind::enable:
      profiles.enable(edit.label, true);
      break;
    case MachineEditKind::disable:
      profiles.enable(edit.label, false);
      break;
    case MachineEditKind::place_program:
      profiles.placeProgram(edit.label, edit.value);
      break;
    case MachineEditKind::record_login:
      profiles.recordLogin(edit.label, edit.login_agent, edit.login);
      break;
    }
  }

  void MachineProfileEdits::requireRemoteLabel(const MachineProfiles& profiles, std::string_view label, std::string_view fallback) {
    if (label == profiles.localLabel().value_or(fallback)) {
      throw MachineFailure{MachineError::duplicate_label};
    }
  }

  OwnedMachineEdit OwnedMachineEdit::copy(const MachineEdit& edit) {
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

  MachineEdit OwnedMachineEdit::view() const noexcept {
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

}
