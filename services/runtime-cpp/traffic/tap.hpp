#pragma once

#include "service.hpp"

namespace telar::runtime::traffic {

template <ConcurrentAllocator Memory, typename Plugins>
class Tap {
public:
  explicit Tap(Plugins &plugins, Service<Memory> *traffic) noexcept : plugins_(plugins), traffic_(traffic) {}

  bool listening() const noexcept { return plugins_.listening() || (traffic_ && traffic_->listening()); }

  void submit(CapturedExchange<Memory> &exchange) noexcept {
    if (traffic_) {
      traffic_->submit(exchange);
    }
    plugins_.submit(exchange);
  }

private:
  Plugins &plugins_;
  Service<Memory> *traffic_;
};

}
