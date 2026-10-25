#pragma once

#include "../platform/event_loop.hpp"
#include "socket_interest.hpp"

namespace telar::runtime {

class SocketWatch {
public:
  template <EventLoop Poller>
  void update(Poller &poller, int descriptor, std::uint64_t token, SocketInterest interest) {
    const bool changed = descriptor != descriptor_ || token != token_ || interest != interest_;
    if (descriptor != descriptor_) {
      remove(poller);
      descriptor_ = descriptor;
    }
    token_ = token;
    if (changed && descriptor_ >= 0) {
      poller.readInterest(descriptor_, token_, interest.readable);
      poller.writeInterest(descriptor_, token_, interest.writable);
    }
    interest_ = interest;
  }

  template <EventLoop Poller>
  void remove(Poller &poller) noexcept {
    if (descriptor_ >= 0) {
      poller.remove(descriptor_);
      descriptor_ = -1;
    }
    interest_ = {};
  }

  bool matches(const Event &event) const noexcept {
    return descriptor_ >= 0 && event.descriptor == descriptor_ && event.token == token_;
  }

private:
  int descriptor_ = -1;
  std::uint64_t token_ = 0;
  SocketInterest interest_;
};

}
