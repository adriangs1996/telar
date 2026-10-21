#pragma once

#include "desktop_state.hpp"
#include <memory>

// One asynchronous Mission Control transaction, advanced by the native backend's timer.
class MissionControl final {
public:
  MissionControl();
  ~MissionControl();

  void begin(SpaceOperation operation, const DesktopState &state);
  std::optional<SpaceCompletion> advance(const DesktopState &state);
  std::optional<SpaceOperation> pending() const;
  bool readyForActivation() const;
  void cancel();

private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
