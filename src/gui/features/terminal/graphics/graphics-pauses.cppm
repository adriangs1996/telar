module;
#include "tbc/annotations.hpp"

// The panes whose images are paused after a limit, and when each asks the runtime again.
// Nothing here is exported: only the feature's own units name it, through State.
export module telar.gui.features.terminal.graphics:pauses;

import std;

import :store;
import telar.gui.foundation.model;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::gui::features::terminal::graphics {

  class GraphicsPauses {
  public:
    static constexpr std::size_t capacity = PaneLayout::maximum_panes;
    static constexpr std::uint64_t healthy_window_ns = GraphicsPauseLimits::healthy_window_ns;
    static constexpr std::uint8_t requests_per_window = GraphicsPauseLimits::requests_per_window;
    static constexpr std::uint8_t maximum_doublings = GraphicsPauseLimits::maximum_doublings;

    struct Focus {
      std::uint64_t pane_id = 0;
      std::uint64_t now_ns = 0;
    };

    struct Row {
      std::uint64_t pane_id = 0;
      std::uint64_t since_ns = 0;
      std::uint64_t due_ns = 0;
      ds::Option<std::uint64_t> resumed_ns = ds::none;
      std::uint8_t resyncs = 0;
      std::uint8_t backoff = 0;
      bool waiting = false;
      bool snapshot_begun = false;
    };

    [[nodiscard]] bool contains(std::uint64_t pane_id) const noexcept;
    [[nodiscard]] std::span<const Row> rows() const noexcept;
    [[nodiscard]] std::uint64_t revision() const noexcept;
    [[nodiscard]] ds::Option<std::uint64_t> nextDeadline() const noexcept;

    // The callers' callables are erased here so that the work stays in pauses.cpp.
    template <typename Request, typename Notice>
      requires std::invocable<const Request&, std::uint64_t> && std::invocable<const Notice&, std::uint64_t>
    TBC_GENERIC void pause(std::uint64_t pane_id, std::uint64_t now_ns, const Request& request, const Notice& notice) {
      pause(pane_id, now_ns, PaneCall<void>::of(request), PaneCall<void>::of(notice));
    }

    template <typename Request>
      requires std::invocable<const Request&, std::uint64_t>
    TBC_GENERIC void resumeDue(std::uint64_t now_ns, const Request& request) {
      resumeDue(now_ns, PaneCall<void>::of(request));
    }

    template <typename Request>
      requires std::invocable<const Request&, std::uint64_t>
    TBC_GENERIC void focus(Focus event, const Request& request) {
      focus(event, PaneCall<void>::of(request));
    }

    void snapshotApplied(std::uint64_t pane_id, SnapshotPhase phase, std::uint64_t now_ns) noexcept;

    template <typename Mirrored>
      requires std::predicate<const Mirrored&, std::uint64_t>
    TBC_GENERIC void forgetClosed(const Mirrored& mirrored) {
      forgetClosed(PaneCall<bool>::of(mirrored));
    }

    void reset() noexcept;

  private:
    // A caller's callable over a pane identity, behind a function pointer.
    template <typename Result>
    struct PaneCall {
      const void* context;
      Result (*call)(const void* context, std::uint64_t pane_id);

      // Generic over the caller's callable, so it stays here.
      template <typename Callable>
      TBC_GENERIC static PaneCall of(const Callable& callable) noexcept {
        return {
            .context = &callable,
            .call = [](const void* context, std::uint64_t pane_id) -> Result {
              return static_cast<Result>((*static_cast<const Callable*>(context))(pane_id));
            },
        };
      }

      Result operator()(std::uint64_t pane_id) const;
    };

    void pause(std::uint64_t pane_id, std::uint64_t now_ns, PaneCall<void> request, PaneCall<void> notice);
    void resumeDue(std::uint64_t now_ns, PaneCall<void> request);
    void focus(Focus event, PaneCall<void> request);
    void forgetClosed(PaneCall<bool> mirrored);
    [[nodiscard]] static std::uint64_t elapsed(std::uint64_t now_ns, std::uint64_t since_ns) noexcept;
    [[nodiscard]] static std::uint64_t deadlineAfter(std::uint64_t now_ns, std::uint64_t duration_ns) noexcept;
    static void increment(std::uint8_t& value) noexcept;
    [[nodiscard]] ds::Option<std::size_t> find(std::uint64_t pane_id) const noexcept;
    [[nodiscard]] std::size_t oldest() const noexcept;
    std::size_t start(std::uint64_t pane_id, std::uint64_t now_ns, PaneCall<void> request);
    void remove(std::size_t slot) noexcept;
    void setWaiting(std::size_t slot, bool waiting) noexcept;
    void resume(std::size_t slot, std::uint64_t now_ns) noexcept;

    ds::Array<Row, capacity> rows_{};
    std::size_t count_ = 0;
    std::size_t waiting_count_ = 0;
    std::uint64_t revision_ = 0;
  };

}
