module;
#include "tbc/annotations.hpp"

export module telar.gui.links.path_expansion;

import std;
import telar.tbc;

import telar.gui.foundation.text;
import telar.base.editors;
import telar.base.memory.containers;
import telar.gui.foundation.terminal;
import telar.wire.editor;
import telar.wire.vocabulary;

// Interface: links/link_text.cppm
export {
  namespace telar::gui {

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

// Interface: links/editor_launch.cppm
export {
  namespace telar::gui {

    class EditorLaunch {
    public:
      static constexpr std::size_t maximum_arguments = 3;
      static constexpr std::size_t position_bytes = 64;

      EditorLaunch() = default;
      ~EditorLaunch() = default;
      EditorLaunch(const EditorLaunch&) = delete;
      EditorLaunch& operator=(const EditorLaunch&) = delete;
      EditorLaunch(EditorLaunch&&) = delete;
      EditorLaunch& operator=(EditorLaunch&&) = delete;

      // The arguments view copies this launch keeps, valid until its next call.
      [[nodiscard]] std::span<const std::string_view> arguments(std::string_view executable, std::string_view path, std::uint32_t line, std::uint32_t column);

    private:
      enum class Convention : std::uint8_t {
        vim,
        plus_line_column,
        nano,
        path_suffix,
        goto_flag,
        none,
      };

      struct Position {
        std::string_view path;
        std::uint32_t line;
        std::uint32_t column;
      };

      [[nodiscard]] static std::string_view columnSeparator(Convention convention) noexcept;

      [[nodiscard]] static Convention conventionOf(std::string_view executable);

      void writePosition(Position position, Convention convention);

      BoundedText<LinkText::maximum_uri_bytes> executable_;
      BoundedText<LinkText::maximum_uri_bytes> path_;
      BoundedText<LinkText::maximum_uri_bytes + position_bytes> position_;
      tbc::view<std::array<std::string_view, maximum_arguments>, tbc::lt::self> arguments_;
    };

  }
}

// Interface: links/editor_opening.cppm
export {
  namespace telar::gui {

    struct EditorSource {
      std::uint64_t pane_id = 0;
      std::uint64_t pane_generation = 0;
      std::uint64_t attachment_generation = 0;
      TabLocation location{};
    };

    class EditorTarget {
    public:
      EditorTarget(std::string_view editor, std::string_view path, std::uint32_t line, std::uint32_t column);

      [[nodiscard]] std::string_view editor() const noexcept;

      [[nodiscard]] std::string_view path() const noexcept;

      [[nodiscard]] std::uint32_t line() const noexcept;

      [[nodiscard]] std::uint32_t column() const noexcept;

    private:
      runtime::FixedText<LinkText::maximum_uri_bytes> editor_;
      runtime::FixedText<LinkText::maximum_uri_bytes> path_;
      std::uint32_t line_;
      std::uint32_t column_;
    };

    struct EditorRequest {
      std::uint64_t request_id;
      EditorSource source;
      EditorTarget target;

      [[nodiscard]] OpenEditor message() const noexcept;
    };

    class EditorOpening {
    public:
      void begin(const EditorRequest& request);

      [[nodiscard]] std::optional<EditorRequest> complete(std::uint64_t request_id);

      [[nodiscard]] bool owns(std::uint64_t request_id) const noexcept;

      void reset() noexcept;

    private:
      std::optional<EditorRequest> pending_;
    };

  }
}

// Interface: links/link_grid.cppm
export {
  namespace telar::gui {

    struct LinkGrid {
      std::span<const CellValue> cells;
      std::uint16_t columns = 0;
      std::uint16_t rows = 0;
      Scroll scroll{};
      std::span<const Byte> row_flags;

      [[nodiscard]] std::optional<std::size_t> cellIndex(CellPosition point) const noexcept;

      [[nodiscard]] std::optional<std::size_t> previous(std::size_t index) const noexcept;

      [[nodiscard]] std::optional<std::size_t> next(std::size_t index) const noexcept;

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

// Interface: links/path_expansion.cppm
export {
  namespace telar::gui {

    template <typename Environment>
    concept PathEnvironment = requires(const Environment& environment, const char* name) {
      { environment(name) } -> std::same_as<std::optional<std::string_view>>;
    };

    struct PathExpansionInput {
      std::string_view text;
      std::string_view base;
    };

    class PathExpansion {
    public:
      static constexpr std::size_t maximum_bytes = LinkText::maximum_uri_bytes;
      using PathText = runtime::FixedText<maximum_bytes>;

      template <PathEnvironment Environment>
      [[nodiscard]] TBC_GENERIC static PathText expand(PathExpansionInput input, const Environment& environment) {
        const Lookup<Environment> lookup{environment};

        return expandWith(input, lookup);
      }

    private:
      // The variables expand reads, whatever environment the caller holds them in.
      class Variables {
      public:
        [[nodiscard]] virtual std::optional<std::string_view> operator()(const char* name) const = 0;

      protected:
        Variables() = default;
        ~Variables() = default;
        Variables(const Variables&) = default;
        Variables& operator=(const Variables&) = default;
      };

      template <PathEnvironment Environment>
      class TBC_GENERIC Lookup final : public Variables {
      public:
        explicit Lookup(const Environment& source) noexcept
            : source_(source) {}

        [[nodiscard]] std::optional<std::string_view> operator()(const char* name) const override {
          return source_(name);
        }

      private:
        const Environment& source_;
      };

      [[nodiscard]] static PathText expandWith(PathExpansionInput input, const Variables& environment);

      [[nodiscard]] static bool nameByte(char byte) noexcept;

      [[nodiscard]] static BoundedText<maximum_bytes> substitute(std::string_view text, const Variables& environment);

      [[nodiscard]] static PathText collapse(std::string_view path);
    };

  }
}

// Interface: links/pointer_policy.cppm
export {
  namespace telar::gui {

    struct LinkModifiers {
      bool native = false;
      bool shift = false;
      bool alt = false;

      bool operator==(const LinkModifiers&) const = default;
    };

    enum class LinkAffordance : std::uint8_t {
      text,
      pointer,
      link,
    };

    enum class LinkButton : std::uint8_t {
      left,
      middle,
      right,
    };

    enum class LinkPress : std::uint8_t {
      passthrough,
      arm_shared,
      arm_exclusive,
      copy,
      discard,
    };

    struct LinkPressInput {
      LinkButton button = LinkButton::left;
      LinkModifiers modifiers{};
      bool child_tracking = false;
      bool has_link = false;
      bool openable = false;
      bool frame_presented = false;
    };

    class LinkPointerPolicy {
    public:
      [[nodiscard]] static constexpr LinkAffordance hover(std::optional<LinkScheme> scheme, LinkModifiers modifiers, bool eligible = true) noexcept {
        if (!eligible || !scheme) {
          return LinkAffordance::text;
        }

        if (modifiers.alt) {
          return LinkAffordance::pointer;
        }

        return *scheme == LinkScheme::path && !modifiers.native ? LinkAffordance::text : LinkAffordance::link;
      }

      [[nodiscard]] static constexpr LinkPress press(LinkPressInput input) noexcept {
        if (!input.has_link || input.button == LinkButton::middle) {
          return LinkPress::passthrough;
        }

        if (input.button == LinkButton::right) {
          return input.frame_presented ? LinkPress::copy : LinkPress::discard;
        }

        if (input.child_tracking && !input.modifiers.shift) {
          return LinkPress::passthrough;
        }

        if (input.modifiers.native) {
          return input.openable ? LinkPress::arm_exclusive : LinkPress::discard;
        }

        return input.openable ? LinkPress::arm_shared : LinkPress::passthrough;
      }
    };

  }
}
