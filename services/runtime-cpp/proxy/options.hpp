#pragma once

#include "capture_limits.hpp"
#include "host_policy.hpp"

namespace telar::runtime {

template <Allocator Memory>
struct ProxyOptions {
  explicit ProxyOptions(Memory &memory)
      : authority_directory(AllocatorRef<char, Memory>{memory}),
        intercept_hosts(memory) {}

  String<Memory> authority_directory;
  ProxyHostPolicy<Memory> intercept_hosts;
  ProxyCaptureLimits capture;
  bool enabled = false;
  bool anonymous_tunnels = false;
  bool network_capture = false;
};

}
