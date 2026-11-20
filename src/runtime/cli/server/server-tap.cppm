module;
#include "tbc/annotations.hpp"

export module telar.runtime.cli.server:tap;

import std;

import telar.runtime.traffic.control_backend;
import telar.runtime.traffic.control_protocol;
import telar.runtime.vocabulary.exchange;

// Interface: traffic/tap.cppm
export {
  namespace telar::runtime::traffic {

    // Generic over the caller's plugins, and called for every captured exchange.
    template <typename Plugins>
    class TBC_GENERIC Tap {
    public:
      inline explicit Tap(Plugins& plugins, Service* traffic) noexcept
          : plugins_(plugins),
            traffic_(traffic) {}

      inline FlowControl* flowControl() noexcept {
        return traffic_;
      }

      [[nodiscard]] inline bool listening() const noexcept {
        return plugins_.listening() || ((traffic_ != nullptr) && traffic_->listening());
      }

      inline void submit(CapturedExchange& exchange) noexcept {
        if (traffic_ != nullptr) {
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
