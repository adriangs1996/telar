export module telar.gui.links.link_hover;

import std;

import telar.gui.core.metrics;
import telar.gui.links.cell_links;

import telar.gui.core.unicode_scalar;

import telar.gui.links.path_expansion;
import telar.base.diagnostics;
import telar.gui.core.primitives;
import telar.gui.terminal.screen;
import telar.wire.vocabulary;

// Interface: links/link_hit.cppm
export {
  namespace telar::gui {

    struct LinkHit {
      std::uint64_t pane_id = 0;
      std::uint64_t generation = 0;
      TabLocation location;
      Rect content;
      std::uint32_t scroll_offset = 0;
      Rect area;
      LinkMatch match;

      [[nodiscard]] bool operator==(const LinkHit& other) const noexcept;
    };

  }
}

// Interface: links/link_gesture.cppm
export {
  namespace telar::gui {

    class LinkGesture {
    public:
      void begin(const LinkHit& hit, ViewVersion version);

      void validate(const std::optional<LinkHit>& current, ViewVersion version);

      [[nodiscard]] std::optional<LinkHit> finish(const std::optional<LinkHit>& current, ViewVersion version);

      void cancel() noexcept;

      [[nodiscard]] bool active() const noexcept;

    private:
      std::optional<LinkHit> pressed_;
      ViewVersion version_;
    };

  }
}

// Interface: links/link_hover.cppm
export {
  namespace telar::gui {

    struct LinkPresentation {
      TerminalSurface surface;
      std::optional<LinkHit> link;
      std::optional<Rect> cover;
    };

    class LinkHover {
    public:
      [[nodiscard]] bool assign(std::optional<LinkHit> hit, const TerminalSurface& surface, bool frame_presented);

      void clear() noexcept;

      [[nodiscard]] bool openable(const TerminalSurface& surface) const noexcept;

      [[nodiscard]] bool surfaceVisible(const TerminalSurface& surface) const noexcept;

      [[nodiscard]] bool covers(Point point) const noexcept;

      [[nodiscard]] bool needsPresentation(const TerminalSurface& surface, const std::optional<Rect>& cover) const noexcept;

      [[nodiscard]] LinkPresentation prepare(const TerminalSurface& surface, std::optional<Rect> cover) const;

      void present(const LinkPresentation& frame, bool delivered = true);

      [[nodiscard]] const std::optional<LinkHit>& current() const noexcept;

    private:
      std::optional<LinkHit> current_;
      std::optional<LinkHit> shown_;
      std::optional<TerminalSurface> shown_surface_;
      std::optional<Rect> shown_cover_;
    };

  }
}

// Interface: links/link_opening.cppm
export {
  namespace telar::gui {

    class LinkOpening {
    public:
      [[nodiscard]] bool request(const LinkTarget& target);

      [[nodiscard]] std::optional<LinkTarget> complete();

      void schedulingFailed() noexcept;

      [[nodiscard]] bool active() const noexcept;

    private:
      bool active_ = false;
      std::optional<LinkTarget> pending_;
    };

  }
}

// Interface: links/link_regions.cppm
export {
  namespace telar::gui {

    struct LinkRegion {
      std::uint16_t x;
      std::uint16_t y;
      std::uint16_t width;

      bool operator==(const LinkRegion&) const = default;
    };

    class LinkRegions {
    public:
      struct Viewport {
        std::uint16_t columns;
        std::uint16_t rows;
      };

      LinkRegions(const LinkMatch& match, LinkGrid grid, std::span<const MetadataRun> runs);

      LinkRegions(const LinkMatch& match, LinkGrid grid, std::span<const MetadataRun> runs, Viewport viewport);

      [[nodiscard]] std::optional<LinkRegion> next() noexcept;

    private:
      [[nodiscard]] std::optional<LinkRegion> nextMetadataRun(std::uint16_t link_index) noexcept;

      [[nodiscard]] std::optional<LinkRegion> clipped(std::uint32_t row, std::uint32_t left, std::uint32_t right) const noexcept;

      const LinkMatch& match_;
      LinkGrid grid_;
      std::span<const MetadataRun> runs_;
      Viewport viewport_;
      std::uint64_t row_;
      std::size_t run_index_ = 0;
    };

  }
}
