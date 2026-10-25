#pragma once

#include "process_inspector.hpp"
#include <algorithm>

namespace telar::runtime {

struct ProcessCache {
  static constexpr unsigned acquisition_attempts = 6;

  bool needsIdentification(pid_t foreground, bool recheck) const noexcept {
    return foreground > 0 && (recheck || foreground != group || (identified.provider == AgentProvider::unknown && attempts < acquisition_attempts));
  }

  AgentProvider preferred(pid_t foreground) const noexcept {
    return foreground == group ? identified.provider : AgentProvider::unknown;
  }

  void update(pid_t foreground, const IdentifiedProcess &process, bool installed) noexcept {
    attempts = process.provider != AgentProvider::unknown ? 0 : foreground == group ? std::min(attempts + 1, acquisition_attempts)
                                                                                    : 1;
    group = foreground;
    identified = process;
    if (identified.name.view().empty()) {
      identified.name.assign("process");
    }
    hooks_installed = installed;
  }

  pid_t group = 0;
  IdentifiedProcess identified;
  unsigned attempts = 0;
  bool hooks_installed = false;
};

}
