module;
#include "tbc/annotations.hpp"

export module telar.gui.graphics.pauses;

import std;

export import telar.gui.layout.geometry;
import telar.base.diagnostics;
import telar.wire.vocabulary;

// Interface: graphics/artwork_resize.cppm
export {
  namespace telar::gui {

    struct RgbaImageView {
      static constexpr std::size_t channels = 4;
      static constexpr auto maximum_extent = std::numeric_limits<std::uint16_t>::max();

      std::span<const std::byte> pixels;
      std::size_t stride = 0;
      std::size_t width = 0;
      std::size_t height = 0;

      [[nodiscard]] bool valid(std::size_t extent_limit = maximum_extent) const noexcept;
      [[nodiscard]] std::array<std::uint8_t, channels> pixel(std::size_t x, std::size_t y) const noexcept;
    };

    class ArtworkResize {
    public:
      static constexpr std::size_t color_channels = 3;
      static constexpr std::uint32_t channel_maximum = 255;

      [[nodiscard]] static bool square(RgbaImageView source, std::span<std::uint8_t> destination, std::size_t side) noexcept;
      [[nodiscard]] static bool rectangle(RgbaImageView source, std::span<std::uint8_t> destination, std::size_t width, std::size_t height) noexcept;
      static void premultiply(std::span<std::uint8_t> pixels) noexcept;

    private:
      struct Axis {
        std::size_t extent;
        float scale;
      };

      struct Span {
        std::size_t first;
        std::size_t end;
        float lead;
        float trail;

        [[nodiscard]] float weight(std::size_t index) const noexcept;
        [[nodiscard]] static Span of(std::size_t index, Axis axis) noexcept;
      };

      struct Tap {
        std::size_t index;
        std::size_t next;
        float fraction;

        [[nodiscard]] static Tap of(std::size_t index, Axis axis) noexcept;
      };

      struct Sample {
        std::array<float, color_channels> colors{};
        float alpha = 0;
        float total = 0;

        void add(std::span<const std::uint8_t, RgbaImageView::channels> pixel, float weight) noexcept;
        void write(std::span<std::uint8_t, RgbaImageView::channels> output) const noexcept;
      };

      [[nodiscard]] static Sample areaSample(RgbaImageView source, Span columns, Span rows) noexcept;
      [[nodiscard]] static Sample linearSample(RgbaImageView source, Tap x, Tap y) noexcept;
    };

  }
}

// Interface: graphics/pauses.cppm
export {
  namespace telar::gui {

    class GraphicsPauses {
    public:
      static constexpr std::size_t capacity = PaneLayout::maximum_panes;
      static constexpr std::uint64_t healthy_window_ns = 60'000'000'000;
      static constexpr std::uint8_t requests_per_window = 3;
      static constexpr std::uint8_t maximum_doublings = 4;

      struct Focus {
        std::uint64_t pane_id = 0;
        std::uint64_t now_ns = 0;
      };

      struct Row {
        std::uint64_t pane_id = 0;
        std::uint64_t since_ns = 0;
        std::uint64_t due_ns = 0;
        std::optional<std::uint64_t> resumed_ns = std::nullopt;
        std::uint8_t resyncs = 0;
        std::uint8_t backoff = 0;
        bool waiting = false;
        bool snapshot_begun = false;
      };

      [[nodiscard]] bool contains(std::uint64_t pane_id) const noexcept;
      [[nodiscard]] std::span<const Row> rows() const noexcept;
      [[nodiscard]] std::uint64_t revision() const noexcept;
      [[nodiscard]] std::optional<std::uint64_t> nextDeadline() const noexcept;

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
      [[nodiscard]] std::optional<std::size_t> find(std::uint64_t pane_id) const noexcept;
      [[nodiscard]] std::size_t oldest() const noexcept;
      std::size_t start(std::uint64_t pane_id, std::uint64_t now_ns, PaneCall<void> request);
      void remove(std::size_t slot) noexcept;
      void setWaiting(std::size_t slot, bool waiting) noexcept;
      void resume(std::size_t slot, std::uint64_t now_ns) noexcept;

      std::array<Row, capacity> rows_{};
      std::size_t count_ = 0;
      std::size_t waiting_count_ = 0;
      std::uint64_t revision_ = 0;
    };

  }
}
