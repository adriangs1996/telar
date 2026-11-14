module;
#include "tbc/annotations.hpp"

export module telar.runtime.cli.server:tap;

import std;

export import telar.runtime.traffic.control_backend;
import telar.base.diagnostics;
import telar.platform.primitives;

// Interface: traffic/tap.cppm
export {
  namespace telar::runtime::traffic {

    // Generic over the caller's plugins, and called for every captured exchange.
    template <typename Plugins>
    class TBC_HOT_PATH Tap {
    public:
      inline explicit Tap(Plugins& plugins, Service* traffic) noexcept
          : plugins_(plugins),
            traffic_(traffic) {}

      inline FlowControl* flowControl() noexcept {
        return traffic_;
      }

      inline bool listening() const noexcept {
        return plugins_.listening() || (traffic_ && traffic_->listening());
      }

      inline void submit(CapturedExchange& exchange) noexcept {
        if (traffic_) {
          traffic_->submit(exchange);
        }

        plugins_.submit(exchange);
      }

    private:
      Plugins& plugins_;
      Service* traffic_;
    };

  }
}
