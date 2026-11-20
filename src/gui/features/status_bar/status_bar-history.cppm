module;
#include "tbc/annotations.hpp"

// The CPU's recent samples, which the bar draws as a sparkline.
export module telar.gui.features.status_bar:history;

import std;
import telar.tbc;
import telar.base.ds;

// Interface: core/cpu_history.cppm
export {
  namespace telar::gui::features::status_bar {

    class CpuHistory {
    public:
      static constexpr std::size_t capacity = 32;
      using Samples = ds::Array<std::uint8_t, capacity>;

      void push(std::uint8_t percent) noexcept;

      // The samples are copied into the buffer, region `a`, in the order they were taken.
      [[nodiscard]] tbc::val_a<std::span<const std::uint8_t>> ordered(tbc::mut_a<Samples> buffer) const noexcept;

    private:
      Samples samples_{};
      std::size_t count_ = 0;
      std::size_t next_ = 0;
    };

  }
}
