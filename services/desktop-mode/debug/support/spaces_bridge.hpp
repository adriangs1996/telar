#pragma once

#include <cstdint>
#include <memory>

// Observes real window visibility and Mission Control entry during the integration check.
class SpacesProbe final {
public:
  SpacesProbe();
  ~SpacesProbe();
  std::uint32_t showWindow(std::uint64_t space);
  bool windowVisible(std::uint32_t window) const;
  bool windowInSpace(std::uint32_t window, std::uint64_t space) const;
  unsigned missionControlEntries() const;
  void holdCreationConfirmation(bool hold);

private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
