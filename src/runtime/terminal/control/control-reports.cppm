module;
#include "tbc/annotations.hpp"

export module telar.runtime.terminal.control:reports;

import std;
import telar.base.memory.allocators;
import :reply;
import :size_report;
import :vt_state;

export namespace telar::runtime::control {

  struct ClientFacts {
    bool light = false;
    bool visible = false;
    bool focused = false;
  };

  enum class Report : std::uint8_t {
    scheme = 1,
    visibility = 2,
    focus = 4,
    size = 8,
  };

  // Generic over the caller's allocator and response sink, so it stays here.
  template <Allocator Memory>
  class TBC_GENERIC Reports {
  public:
    explicit Reports(Memory& memory)
        : reply_(memory) {}

    void changed(Report report) noexcept {
      pending_ |= static_cast<std::uint8_t>(report);
    }

    [[nodiscard]] bool pending() const noexcept {
      return pending_ != 0 || prepared_;
    }

    void discard() noexcept {
      reply_.discard();
      pending_ = 0;
      prepared_ = false;
    }

    // Unencoded desktop updates coalesce to the latest facts. Once encoded,
    // bytes remain immutable until the PTY queue admits the entire report.
    template <typename Sink>
    bool publish(Sink& queue, const VtState& state, ClientFacts facts, bool enabled) {
      while (pending()) {
        if (!prepared_) {
          prepare(state, facts, enabled);
        }

        if (!reply_.publish(queue)) {
          return false;
        }

        reply_.clear();
        prepared_ = false;
      }

      return true;
    }

  private:
    // Takes the first pending report in priority order, and encodes it when reports are enabled.
    void prepare(const VtState& state, ClientFacts facts, bool enabled) {
      for (const auto report : {Report::scheme, Report::visibility, Report::focus, Report::size}) {
        const auto bit = static_cast<std::uint8_t>(report);
        if ((pending_ & bit) == 0) {
          continue;
        }

        pending_ ^= bit;
        if (enabled) {
          encode(report, state, facts);
        }

        prepared_ = true;
        return;
      }
    }

    void encode(Report report, const VtState& state, ClientFacts facts) {
      switch (report) {
      case Report::scheme:
        if (state.mode(scheme_mode)) {
          reply_.append(facts.light ? "\x1b[?997;2n" : "\x1b[?997;1n");
        }

        break;
      case Report::visibility:
        if (state.mode(visibility_mode)) {
          reply_.append(facts.visible ? "\x1b[?999;1n" : "\x1b[?999;2n");
        }

        break;
      case Report::focus:
        if (state.mode(focus_mode)) {
          reply_.append(facts.focused ? "\x1b[I" : "\x1b[O");
        }

        break;
      case Report::size:
        if (state.mode(size_mode)) {
          sizeReport<SizeReport::event>(reply_, state.size());
        }

        break;
      }
    }

    static constexpr unsigned scheme_mode = 2031;
    static constexpr unsigned visibility_mode = 2033;
    static constexpr unsigned focus_mode = 1004;
    static constexpr unsigned size_mode = 2048;
    Reply<Memory> reply_;
    std::uint8_t pending_ = 0;
    bool prepared_ = false;
  };

}
