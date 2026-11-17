export module telar.gui.links.cell_links;

import std;
import telar.tbc;

import telar.gui.links.path_expansion;

import telar.gui.foundation.text;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.base.text;
import telar.gui.foundation.core;
import telar.gui.foundation.terminal;

// Interface: links/uri_view.cppm
export {
  namespace telar::gui {

    // Every part views the parsed text, region `a`.
    struct UriView {
      tbc::view<std::string_view, tbc::lt::a> scheme;
      tbc::view<std::string_view, tbc::lt::a> path;
      tbc::view<std::optional<std::string_view>, tbc::lt::a> host = std::nullopt;
      tbc::view<std::optional<std::string_view>, tbc::lt::a> user = std::nullopt;
      tbc::view<std::optional<std::string_view>, tbc::lt::a> password = std::nullopt;
      std::optional<std::uint16_t> port = std::nullopt;
      tbc::view<std::optional<std::string_view>, tbc::lt::a> query = std::nullopt;
      tbc::view<std::optional<std::string_view>, tbc::lt::a> fragment = std::nullopt;

      [[nodiscard]] static std::optional<UriView> parse(std::string_view text);

    private:
      [[nodiscard]] static std::optional<std::uint16_t> parsePort(std::string_view text) noexcept;

      bool authority(tbc::view<std::string_view, tbc::lt::a> text, bool empty_authority_has_path);
    };

  }
}

// Interface: links/uri_recognizer.cppm
export {
  namespace telar::gui {

    class UriRecognizer {
    public:
      [[nodiscard]] static std::optional<LinkScheme> classify(std::string_view text);

      [[nodiscard]] static std::optional<LinkTextMatch> extract(std::string_view line, std::size_t byte_offset);

    private:
      struct Prefix {
        std::string_view text;
        LinkScheme scheme;
      };

      static constexpr auto prefixes = std::to_array<Prefix>({
          {.text = "https://", .scheme = LinkScheme::https},
          {.text = "http://", .scheme = LinkScheme::http},
          {.text = "file://", .scheme = LinkScheme::file},
          {.text = "mailto:", .scheme = LinkScheme::external},
          {.text = "ftp://", .scheme = LinkScheme::external},
          {.text = "ssh:", .scheme = LinkScheme::external},
          {.text = "git://", .scheme = LinkScheme::external},
          {.text = "tel:", .scheme = LinkScheme::external},
          {.text = "magnet:", .scheme = LinkScheme::external},
          {.text = "ipfs://", .scheme = LinkScheme::external},
          {.text = "ipns://", .scheme = LinkScheme::external},
          {.text = "gemini://", .scheme = LinkScheme::external},
          {.text = "gopher://", .scheme = LinkScheme::external},
          {.text = "news:", .scheme = LinkScheme::external},
      });

      [[nodiscard]] static std::optional<Prefix> prefixAt(std::string_view text);

      [[nodiscard]] static bool validStart(std::string_view line, std::size_t index) noexcept;

      [[nodiscard]] static std::size_t trimEnd(std::string_view text) noexcept;
    };

  }
}

// Interface: links/link_target.cppm
export {
  namespace telar::gui {

    class LinkTarget {
    public:
      [[nodiscard]] static std::optional<LinkTarget> fromUri(std::string_view text);

      [[nodiscard]] static std::optional<LinkTarget> fromPath(std::string_view text);

      [[nodiscard]] LinkScheme scheme() const noexcept;

      [[nodiscard]] std::string_view text() const noexcept;

      bool operator==(const LinkTarget& other) const noexcept;

    private:
      LinkTarget(LinkScheme scheme, std::string_view text);

      LinkScheme scheme_;
      runtime::FixedText<LinkText::maximum_uri_bytes> text_;
    };

  }
}

// Interface: links/link_match.cppm
export {
  namespace telar::gui {

    struct LinkMatch {
      LinkTarget target;
      CellPosition start;
      CellPosition end;
      std::optional<std::uint16_t> metadata_index = std::nullopt;

      bool operator==(const LinkMatch&) const = default;
    };

  }
}

// Interface: links/markdown_links.cppm
export {
  namespace telar::gui {

    class MarkdownLinks {
    public:
      [[nodiscard]] static std::optional<LinkTextMatch> extract(std::string_view line, std::size_t byte_offset);

    private:
      [[nodiscard]] static std::optional<LinkTextMatch> parseAt(std::string_view line, std::size_t start);
    };

  }
}

// Interface: links/path_recognizer.cppm
export {
  namespace telar::gui {

    struct PathLocation {
      std::string_view path;
      std::uint32_t line = 0;
      std::uint32_t column = 0;
    };

    class PathRecognizer {
    public:
      [[nodiscard]] static std::optional<LinkTextMatch> extract(std::string_view line, std::size_t byte_offset);

      [[nodiscard]] static PathLocation locate(std::string_view text);

      [[nodiscard]] static std::optional<PathLocation> fragment(std::string_view text);

    private:
      static constexpr std::size_t maximum_number_digits = 9;

      [[nodiscard]] static std::size_t numberLength(std::string_view text) noexcept;

      [[nodiscard]] static std::uint32_t number(std::string_view text) noexcept;

      [[nodiscard]] static std::size_t positionEnd(std::string_view token, std::size_t colon);

      [[nodiscard]] static bool looksLikePath(std::string_view text, bool positioned);

      [[nodiscard]] static std::size_t trimLeading(std::string_view text) noexcept;

      [[nodiscard]] static std::size_t trimTrailing(std::string_view text) noexcept;

      [[nodiscard]] static bool tokenByte(char byte) noexcept;
    };

  }
}

// Interface: links/cell_links.cppm
export {
  namespace telar::gui {

    class CellLinks {
    public:
      static constexpr std::size_t window_bytes = (LinkText::maximum_span_bytes * 2) + (CellValue::text_capacity * 2);
      static constexpr std::size_t maximum_walk_cells = window_bytes * 2;

      template <Allocator Memory>
      [[nodiscard]] static std::optional<LinkMatch> text(const Screen<Memory>& screen, CellPosition point);

      template <Allocator Memory>
      [[nodiscard]] static std::optional<LinkMatch> resolve(const Screen<Memory>& screen, CellPosition point);

      [[nodiscard]] static std::optional<LinkMatch> match(const LinkGrid& grid, CellPosition point);

    private:
      struct Window {
        std::size_t length = 0;
        std::size_t cursor = 0;
      };

      [[nodiscard]] static std::optional<std::size_t> windowStart(const LinkGrid& grid, std::size_t index) noexcept;

      [[nodiscard]] static std::optional<Window> readWindow(const LinkGrid& grid, std::size_t index, std::size_t cursor, std::span<char> storage) noexcept;

      [[nodiscard]] static std::optional<std::pair<CellPosition, CellPosition>> positions(const LinkGrid& grid, std::size_t index, TextRange extent) noexcept;
    };

    extern template std::optional<LinkMatch> CellLinks::text<telar::Memory>(const Screen<telar::Memory>& screen, CellPosition point);
    extern template std::optional<LinkMatch> CellLinks::text<telar::ConcurrentMemory>(const Screen<telar::ConcurrentMemory>& screen, CellPosition point);
    extern template std::optional<LinkMatch> CellLinks::resolve<telar::Memory>(const Screen<telar::Memory>& screen, CellPosition point);
    extern template std::optional<LinkMatch> CellLinks::resolve<telar::ConcurrentMemory>(const Screen<telar::ConcurrentMemory>& screen, CellPosition point);

  }
}

// Interface: links/file_path.cppm
export {
  namespace telar::gui {

    class FilePath {
    public:
      [[nodiscard]] static FilePath parse(const LinkTarget& target);

      [[nodiscard]] std::string_view text() const noexcept;

      [[nodiscard]] std::uint32_t line() const noexcept;

      [[nodiscard]] std::uint32_t column() const noexcept;

    private:
      static constexpr std::size_t maximum_host_bytes = 255;
      static constexpr std::size_t escape_bytes = 3;
      static constexpr int hexadecimal_base = 16;

      enum class EscapePolicy : std::uint8_t {
        strict,
        tolerant,
      };

      explicit FilePath(PathLocation location);

      [[nodiscard]] static FilePath fromProse(std::string_view text);

      [[nodiscard]] static std::optional<char> escapedByte(std::string_view text, EscapePolicy policy) noexcept;

      template <std::size_t Capacity>
      [[nodiscard]] static BoundedText<Capacity> decode(std::string_view text, EscapePolicy policy = EscapePolicy::strict);

      static void validateHost(std::string_view host);

      [[nodiscard]] static FilePath fromUri(std::string_view text);

      runtime::FixedText<LinkText::maximum_uri_bytes> path_;
      std::uint32_t line_ = 0;
      std::uint32_t column_ = 0;
    };

  }
}
