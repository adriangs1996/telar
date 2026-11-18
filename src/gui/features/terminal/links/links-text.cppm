// A link in the terminal's cells: the text a URI, a path or a Markdown link spans, what it
// targets, and the file and position a file link names.
export module telar.gui.features.terminal.links:text;

import std;
import telar.tbc;

import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.base.text;
import telar.gui.foundation.core;
import telar.gui.foundation.terminal;
import telar.gui.foundation.text;
import telar.wire.vocabulary;
import telar.base.ds;

// Interface: links/link_text.cppm
export {
  namespace telar::gui::features::terminal::links {

    enum class LinkScheme : std::uint8_t {
      file,
      http,
      https,
      external,
      path,
    };

    struct TextRange {
      std::size_t start = 0;
      std::size_t end = 0;

      [[nodiscard]] tbc::view<std::string_view, tbc::lt::a> view(tbc::view<std::string_view, tbc::lt::a> text) const;

      bool operator==(const TextRange&) const = default;
    };

    struct LinkTextMatch {
      LinkScheme scheme = LinkScheme::external;
      TextRange extent;
      TextRange destination;
    };

    struct LinkText {
      static constexpr std::size_t maximum_uri_bytes = 4096;
      static constexpr std::size_t maximum_label_bytes = 512;
      static constexpr std::size_t markdown_delimiter_bytes = 4;
      static constexpr std::size_t maximum_span_bytes = maximum_uri_bytes + maximum_label_bytes + markdown_delimiter_bytes;
      static constexpr unsigned first_non_ascii = 0x80;
      static constexpr unsigned delete_control = 0x7f;

      [[nodiscard]] static constexpr bool control(char byte) noexcept {
        return static_cast<unsigned char>(byte) < ' ' || static_cast<unsigned char>(byte) == delete_control;
      }

      [[nodiscard]] static constexpr bool digit(char byte) noexcept {
        return byte >= '0' && byte <= '9';
      }

      [[nodiscard]] static constexpr bool alphanumeric(char byte) noexcept {
        return digit(byte) || (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z');
      }

      [[nodiscard]] static constexpr bool separator(char byte) noexcept {
        return control(byte) || byte == ' ' || std::string_view{"\"'<>`"}.contains(byte);
      }

      [[nodiscard]] static bool validUtf8(std::string_view text) noexcept;
    };

  }
}

// Interface: links/link_grid.cppm
export {
  namespace telar::gui::features::terminal::links {

    struct LinkGrid {
      std::span<const CellValue> cells;
      std::uint16_t columns = 0;
      std::uint16_t rows = 0;
      Scroll scroll{};
      std::span<const Byte> row_flags;

      [[nodiscard]] ds::Option<std::size_t> cellIndex(CellPosition point) const noexcept;

      [[nodiscard]] ds::Option<std::size_t> previous(std::size_t index) const noexcept;

      [[nodiscard]] ds::Option<std::size_t> next(std::size_t index) const noexcept;

      [[nodiscard]] CellPosition position(std::size_t index) const noexcept;

      [[nodiscard]] CellPosition cellEnd(std::size_t index) const noexcept;

      [[nodiscard]] bool complete(CellPosition first, CellPosition last) const noexcept;

    private:
      [[nodiscard]] bool flag(std::size_t row, RowFlag value) const noexcept;

      [[nodiscard]] bool padding(std::size_t index) const noexcept;

      [[nodiscard]] bool joins(std::size_t row) const noexcept;
    };

  }
}

// Interface: links/uri_view.cppm
export {
  namespace telar::gui::features::terminal::links {

    // Every part views the parsed text, region `a`.
    struct UriView {
      tbc::view<std::string_view, tbc::lt::a> scheme;
      tbc::view<std::string_view, tbc::lt::a> path;
      tbc::view<ds::Option<std::string_view>, tbc::lt::a> host = ds::none;
      tbc::view<ds::Option<std::string_view>, tbc::lt::a> user = ds::none;
      tbc::view<ds::Option<std::string_view>, tbc::lt::a> password = ds::none;
      ds::Option<std::uint16_t> port = ds::none;
      tbc::view<ds::Option<std::string_view>, tbc::lt::a> query = ds::none;
      tbc::view<ds::Option<std::string_view>, tbc::lt::a> fragment = ds::none;

      [[nodiscard]] static ds::Option<UriView> parse(std::string_view text);

    private:
      [[nodiscard]] static ds::Option<std::uint16_t> parsePort(std::string_view text) noexcept;

      bool authority(tbc::view<std::string_view, tbc::lt::a> text, bool empty_authority_has_path);
    };

  }
}

// Interface: links/uri_recognizer.cppm
export {
  namespace telar::gui::features::terminal::links {

    class UriRecognizer {
    public:
      [[nodiscard]] static ds::Option<LinkScheme> classify(std::string_view text);

      [[nodiscard]] static ds::Option<LinkTextMatch> extract(std::string_view line, std::size_t byte_offset);

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

      [[nodiscard]] static ds::Option<Prefix> prefixAt(std::string_view text);

      [[nodiscard]] static bool validStart(std::string_view line, std::size_t index) noexcept;

      [[nodiscard]] static std::size_t trimEnd(std::string_view text) noexcept;
    };

  }
}

// Interface: links/link_target.cppm
export {
  namespace telar::gui::features::terminal::links {

    class LinkTarget {
    public:
      [[nodiscard]] static ds::Option<LinkTarget> fromUri(std::string_view text);

      [[nodiscard]] static ds::Option<LinkTarget> fromPath(std::string_view text);

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
  namespace telar::gui::features::terminal::links {

    struct LinkMatch {
      LinkTarget target;
      CellPosition start;
      CellPosition end;
      ds::Option<std::uint16_t> metadata_index = ds::none;

      bool operator==(const LinkMatch&) const = default;
    };

  }
}

// Interface: links/markdown_links.cppm
export {
  namespace telar::gui::features::terminal::links {

    class MarkdownLinks {
    public:
      [[nodiscard]] static ds::Option<LinkTextMatch> extract(std::string_view line, std::size_t byte_offset);

    private:
      [[nodiscard]] static ds::Option<LinkTextMatch> parseAt(std::string_view line, std::size_t start);
    };

  }
}

// Interface: links/path_recognizer.cppm
export {
  namespace telar::gui::features::terminal::links {

    struct PathLocation {
      std::string_view path;
      std::uint32_t line = 0;
      std::uint32_t column = 0;
    };

    class PathRecognizer {
    public:
      [[nodiscard]] static ds::Option<LinkTextMatch> extract(std::string_view line, std::size_t byte_offset);

      [[nodiscard]] static PathLocation locate(std::string_view text);

      [[nodiscard]] static ds::Option<PathLocation> fragment(std::string_view text);

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
  namespace telar::gui::features::terminal::links {

    class CellLinks {
    public:
      static constexpr std::size_t window_bytes = (LinkText::maximum_span_bytes * 2) + (CellValue::text_capacity * 2);
      static constexpr std::size_t maximum_walk_cells = window_bytes * 2;

      template <Allocator Memory>
      [[nodiscard]] static ds::Option<LinkMatch> text(const Screen<Memory>& screen, CellPosition point);

      template <Allocator Memory>
      [[nodiscard]] static ds::Option<LinkMatch> resolve(const Screen<Memory>& screen, CellPosition point);

      [[nodiscard]] static ds::Option<LinkMatch> match(const LinkGrid& grid, CellPosition point);

    private:
      struct Window {
        std::size_t length = 0;
        std::size_t cursor = 0;
      };

      [[nodiscard]] static ds::Option<std::size_t> windowStart(const LinkGrid& grid, std::size_t index) noexcept;

      [[nodiscard]] static ds::Option<Window> readWindow(const LinkGrid& grid, std::size_t index, std::size_t cursor, std::span<char> storage) noexcept;

      [[nodiscard]] static ds::Option<std::pair<CellPosition, CellPosition>> positions(const LinkGrid& grid, std::size_t index, TextRange extent) noexcept;
    };

    extern template ds::Option<LinkMatch> CellLinks::text<telar::Memory>(const Screen<telar::Memory>& screen, CellPosition point);
    extern template ds::Option<LinkMatch> CellLinks::text<telar::ConcurrentMemory>(const Screen<telar::ConcurrentMemory>& screen, CellPosition point);
    extern template ds::Option<LinkMatch> CellLinks::resolve<telar::Memory>(const Screen<telar::Memory>& screen, CellPosition point);
    extern template ds::Option<LinkMatch> CellLinks::resolve<telar::ConcurrentMemory>(const Screen<telar::ConcurrentMemory>& screen, CellPosition point);

  }
}

// Interface: links/file_path.cppm
export {
  namespace telar::gui::features::terminal::links {

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

      [[nodiscard]] static ds::Option<char> escapedByte(std::string_view text, EscapePolicy policy) noexcept;

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
