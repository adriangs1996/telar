// What the window shows of where the user is: its title, from the configured pattern, and the
// cue a view shows once it has waited long enough for its content.
export module telar.gui.features.window:title;

import std;
import telar.tbc;
import telar.base.ds;

// Interface: presentation/window_title.cppm
export {
  namespace telar::gui::features::window {

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
      static tbc::val_a<ds::Option<std::string_view>> token(std::string_view name, tbc::val_a<Tokens> values) noexcept;
      void append(std::string_view value) noexcept;
      void filter();

      ds::Array<char, capacity> bytes_{};
      std::size_t length_ = 0;
    };

  }
}

// Interface: presentation/loading_cue.cppm
export {
  namespace telar::gui::features::window {

    class LoadingCue {
    public:
      static constexpr std::uint64_t delay_ns = 150'000'000;

      [[nodiscard]] bool sample(bool waiting, ds::Option<std::uint64_t> now_ns) noexcept;
      [[nodiscard]] ds::Option<std::uint64_t> deadline() const noexcept;

    private:
      [[nodiscard]] static std::uint64_t visibleAt(std::uint64_t since_ns) noexcept;

      ds::Option<std::uint64_t> since_ns_;
    };

  }
}
