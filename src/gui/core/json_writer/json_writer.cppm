module;
#include "tbc/annotations.hpp"

export module telar.gui.core.json_writer;

import std;

import telar.tbc;
import telar.base.text.json;

// Interface: core/cpu_history.cppm
export {
  namespace telar::gui {

    class CpuHistory {
    public:
      static constexpr std::size_t capacity = 32;
      using Samples = std::array<std::uint8_t, capacity>;

      void push(std::uint8_t percent) noexcept;

      // The samples are copied into the buffer, region `a`, in the order they were taken.
      [[nodiscard]] tbc::view<std::span<const std::uint8_t>, tbc::lt::a> ordered(tbc::view<Samples&, tbc::lt::a> buffer) const noexcept;

    private:
      Samples samples_{};
      std::size_t count_ = 0;
      std::size_t next_ = 0;
    };

  }
}
