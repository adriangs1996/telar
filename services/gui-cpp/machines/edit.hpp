#pragma once

#include "failure.hpp"
#include "identity.hpp"
#include "profile.hpp"
#include "profiles.hpp"
#include <cstdint>
#include <optional>
#include <string_view>

namespace telar::gui {

enum class MachineEditKind : std::uint8_t {
  add,
  remove,
  rename,
  enable,
  disable,
  place_program,
  record_login,
};

struct MachineEdit {
  MachineEditKind kind;
  std::string_view label;
  std::string_view value;
  std::optional<std::string_view> color = std::nullopt;
  bool enabled = true;
  MachineAgent login_agent = MachineAgent::claude;
  MachineLogin login = MachineLogin::pending;
};

struct MachineProfileEdits {
  template <MachineIdentityRandom Random>
  static void apply(MachineProfiles &profiles, const MachineEdit &edit, Random &random, std::string_view local_fallback) {
    switch (edit.kind) {
    case MachineEditKind::add:
      requireRemoteLabel(profiles, edit.label, local_fallback);
      profiles.add(MachineProfile::create(MachineId::generate(random), {
                                                                           .label = edit.label,
                                                                           .destination = edit.value,
                                                                           .color = edit.color,
                                                                           .enabled = edit.enabled,
                                                                       }));
      break;
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

private:
  static void requireRemoteLabel(const MachineProfiles &profiles, std::string_view label, std::string_view fallback) {
    if (label == profiles.localLabel().value_or(fallback)) {
      throw MachineFailure{MachineError::duplicate_label};
    }
  }
};

}
