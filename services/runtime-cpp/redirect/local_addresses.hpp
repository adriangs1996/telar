#pragma once

#include "direction.hpp"
#include "target.hpp"
#include "../platform/error.hpp"
#include <ifaddrs.h>
#include <memory>
#include <net/if.h>

namespace telar::runtime::redirect {

class LocalAddresses {
public:
  LocalAddresses() : addresses_(nullptr, &freeifaddrs) {
    ifaddrs *addresses = nullptr;
    if (::getifaddrs(&addresses) != 0) { throw SystemError{"Read local redirect addresses"}; }
    addresses_.reset(addresses);
  }

  bool contains(const Target &target) const noexcept {
    for (auto *interface = addresses_.get(); interface; interface = interface->ifa_next) {
      if (!interface->ifa_addr || !(interface->ifa_flags & IFF_UP) || (interface->ifa_flags & IFF_LOOPBACK) || interface->ifa_addr->sa_family != target.endpoint.storage.ss_family) { continue; }
      if (interface->ifa_addr->sa_family == AF_INET) {
        const auto &local = reinterpret_cast<const sockaddr_in &>(*interface->ifa_addr).sin_addr;
        const auto &selected = reinterpret_cast<const sockaddr_in &>(target.endpoint.storage).sin_addr;
        if (local.s_addr == selected.s_addr) { return true; }
      } else if (interface->ifa_addr->sa_family == AF_INET6) {
        const auto &local = reinterpret_cast<const sockaddr_in6 &>(*interface->ifa_addr).sin6_addr;
        const auto &selected = reinterpret_cast<const sockaddr_in6 &>(target.endpoint.storage).sin6_addr;
        if (std::memcmp(&local, &selected, sizeof(local)) == 0) { return true; }
      }
    }
    return false;
  }

  static std::array<bool, Target::maximum_targets> selection(std::span<const Target> targets, Direction direction) {
    std::array<bool, Target::maximum_targets> selected{};
    if (targets.size() > selected.size() || (!allowsIncoming(direction) && !allowsOutgoing(direction))) { throw std::invalid_argument{"Invalid redirect address scope"}; }
    if (!allowsIncoming(direction)) { return selected; }
    const LocalAddresses local;
    bool incoming = false;
    for (std::size_t index = 0; index < targets.size(); ++index) {
      selected[index] = local.contains(targets[index]);
      if (direction == Direction::inbound && !selected[index]) { throw std::invalid_argument{"Incoming redirect targets must be assigned to an active non-loopback interface"}; }
      incoming |= selected[index];
    }
    if (!incoming) { throw std::invalid_argument{"Incoming redirection requires a local destination"}; }
    return selected;
  }

private:
  std::unique_ptr<ifaddrs, decltype(&freeifaddrs)> addresses_;
};

}
