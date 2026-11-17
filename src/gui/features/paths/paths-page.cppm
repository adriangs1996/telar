// What the path picker shows: its limits, the matches it found and the page they form.
export module telar.gui.features.paths:page;

import std;

import telar.wire.vocabulary;

namespace telar::gui::features::paths {

  class PathPicker;

}

// Interface: paths/limits.cppm
export {
  namespace telar::gui::features::paths {

    struct PathPickerLimits {
      static constexpr std::size_t root_bytes = 4096;
      static constexpr std::size_t query_bytes = 64;
      static constexpr std::size_t path_bytes = 1024;
      static constexpr std::size_t results = 50;
      static constexpr std::size_t tracked_requests = 32;
      static constexpr std::size_t error_bytes = 128;
      static constexpr std::size_t page_bytes = results * path_bytes;
      static constexpr std::size_t absolute_bytes = root_bytes + path_bytes + 1;
      static constexpr std::size_t quote_escape_bytes = 4;
      static constexpr std::size_t quoted_bytes = quote_escape_bytes * (root_bytes + path_bytes);
    };

  }
}

// Interface: paths/page.cppm
export {
  namespace telar::gui::features::paths {

    enum class PathPickerPhase : std::uint8_t {
      idle,
      loading,
      ready,
      failed,
    };

    struct PathPickerMatch {
      std::uint16_t offset = 0;
      std::uint16_t length = 0;
      PathKind kind = PathKind::file;
      std::array<std::uint16_t, PathPickerLimits::query_bytes> positions{};
      std::uint8_t position_count = 0;

      [[nodiscard]] std::span<const std::uint16_t> highlights() const noexcept;
    };

    // What the picker shows: the matches under its root and where the search stands. A view of
    // the feature's state, valid until a use case changes it.
    class PathPickerPage {
    public:
      explicit PathPickerPage(const PathPicker& picker) noexcept;

      [[nodiscard]] std::span<const PathPickerMatch> matches() const noexcept;

      [[nodiscard]] std::string_view path(const PathPickerMatch& match) const noexcept;

      [[nodiscard]] std::string_view root() const noexcept;

      [[nodiscard]] std::string_view anchor() const noexcept;

      [[nodiscard]] std::string_view error() const noexcept;

      [[nodiscard]] PathPickerPhase phase() const noexcept;

      [[nodiscard]] std::uint64_t paneId() const noexcept;

      [[nodiscard]] std::uint64_t pendingRequest() const noexcept;

      [[nodiscard]] std::uint64_t revision() const noexcept;

      [[nodiscard]] std::uint32_t scanned() const noexcept;

      [[nodiscard]] bool complete() const noexcept;

      [[nodiscard]] bool truncated() const noexcept;

    private:
      const PathPicker* picker_;
    };

  }
}
