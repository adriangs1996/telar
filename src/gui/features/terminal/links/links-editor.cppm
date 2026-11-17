module;
#include "tbc/annotations.hpp"

// The editor a file link opens: its arguments for the editor's conventions, the request the
// runtime answers, and the path expanded and anchored at a pane's directory.
export module telar.gui.features.terminal.links:editor;

import std;
import telar.tbc;

import :text;
import telar.base.editors;
import telar.base.memory.containers;
import telar.gui.foundation.text;
import telar.wire.editor;
import telar.wire.vocabulary;

// Interface: links/editor_launch.cppm
export {
  namespace telar::gui::features::terminal::links {

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
  namespace telar::gui::features::terminal::links {

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

  }
}

// Interface: links/path_expansion.cppm
export {
  namespace telar::gui::features::terminal::links {

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
