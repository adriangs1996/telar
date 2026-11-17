export module telar.gui.presentation.application_mark;

import std;
import telar.tbc;

import telar.wire.vocabulary;

// Interface: presentation/activity_card.cppm
export {
  namespace telar::gui {

    enum class ActivityCard : std::uint8_t {
      agent,
      task,
    };

  }
}

// Interface: presentation/application_mark.cppm
export {
  namespace telar::gui {

    struct ApplicationMark {
      static constexpr float dimmed_alpha = 0.6F;
      static constexpr float atlas_cell_side = 20;
      static constexpr int minimum_cell = 8;
      static constexpr int maximum_cell = 96;

      AgentProvider provider = AgentProvider::unknown;
      std::string_view glyph = "\uea85";
      std::string_view tile = "#2b2a3a";
      std::string_view ink = "#5fb095";

      [[nodiscard]] bool followsTheme() const noexcept;
      [[nodiscard]] static ApplicationMark forApplication(std::string_view name) noexcept;
    };

  }
}

// Interface: presentation/loading_cue.cppm
export {
  namespace telar::gui {

    class LoadingCue {
    public:
      static constexpr std::uint64_t delay_ns = 150'000'000;

      [[nodiscard]] bool sample(bool waiting, std::optional<std::uint64_t> now_ns) noexcept;
      [[nodiscard]] std::optional<std::uint64_t> deadline() const noexcept;

    private:
      [[nodiscard]] static std::uint64_t visibleAt(std::uint64_t since_ns) noexcept;

      std::optional<std::uint64_t> since_ns_;
    };

  }
}

// Interface: presentation/window_title.cppm
export {
  namespace telar::gui {

    class WindowTitle {
    public:
      static constexpr std::size_t capacity = 256;
      static constexpr std::string_view default_title = "Telar";

      struct Tokens {
        std::string_view workspace;
        std::string_view tab;
        std::string_view pane_title;
        std::string_view hostname;
      };

      [[nodiscard]] static WindowTitle render(std::string_view pattern, Tokens tokens);
      void appendSuffix(std::string_view suffix) noexcept;
      [[nodiscard]] std::string_view view() const noexcept;

    private:
      std::size_t expand(std::string_view pattern, Tokens values);
      // A token's value is one of the values, region `a`.
      static tbc::view<std::optional<std::string_view>, tbc::lt::a> token(std::string_view name, tbc::view<Tokens, tbc::lt::a> values) noexcept;
      void append(std::string_view value) noexcept;
      void filter();

      std::array<char, capacity> bytes_{};
      std::size_t length_ = 0;
    };

  }
}
