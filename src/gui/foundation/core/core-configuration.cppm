export module telar.gui.foundation.core:configuration;

import std;

import telar.base.memory.containers;
import telar.base.text;
import telar.wire.vocabulary;
import :theme;
import telar.base.ds;

// Interface: core/configuration.cppm
export {
  namespace telar::gui::inline foundation::inline core {

    // Grid fitting for terminal text; see fonts::GlyphHinting.
    enum class FontHinting : std::uint8_t {
      native,
      light,
      full,
    };

    struct FontConfiguration {
      static constexpr std::size_t name_capacity = 256;
      static constexpr float default_size = 15;
      static constexpr float minimum_size = 6;
      static constexpr float maximum_size = 96;
      static constexpr float minimum_line_height = 0.75F;
      static constexpr float maximum_line_height = 3;
      static constexpr float minimum_letter_spacing = -5;
      static constexpr float maximum_letter_spacing = 20;
      static constexpr std::uint8_t maximum_thicken_strength = 255;

      runtime::FixedText<name_capacity> family;
      runtime::FixedText<name_capacity> style;
      float size = default_size;
      float line_height = 1;
      float letter_spacing = 0;
      // Full grid fitting with half a pixel of dilation measured sharpest at a browser's weight.
      bool thicken = true;
      std::uint8_t thicken_strength = maximum_thicken_strength;
      FontHinting hinting = FontHinting::full;
    };

    struct HistoryConfiguration {
      bool show_agent_commands = false;
      bool enter_runs = false;
      bool match_fts = false;
    };

    enum class PromptMode : std::uint8_t {
      classic,
      telar,
    };

    enum class PromptMotion : std::uint8_t {
      spring,
      ease,
      none,
    };

    enum class PromptKeymap : std::uint8_t {
      emacs,
      vim,
    };

    // A key `client.prompt.bindings` binds: a KeyChord's key, character and modifiers, and the
    // index of its action; `normal` binds it in vim's normal mode instead of typing.
    struct PromptBinding {
      std::uint8_t key = 0;
      std::uint32_t character = 0;
      unsigned modifiers = 0;
      std::uint8_t action = 0;
      bool normal = false;

      bool operator==(const PromptBinding&) const = default;
    };

    // The bindings `client.prompt.bindings` lists, at most as many as the configuration reads: a
    // value of fixed size, copied and compared with the configuration it is part of.
    class PromptBindings {
    public:
      static constexpr std::size_t capacity = 256;

      PromptBindings() = default;

      PromptBindings(std::initializer_list<PromptBinding> bindings) {
        for (const auto& binding : bindings) {
          push(binding);
        }
      }

      void push(const PromptBinding& binding) {
        if (count_ == capacity) {
          throw std::length_error{"more prompt bindings than the configuration reads"};
        }

        entries_.atMut(count_++) = binding;
      }

      [[nodiscard]] std::span<const PromptBinding> view() const noexcept {
        return entries_.view().first(count_);
      }

      [[nodiscard]] std::size_t size() const noexcept {
        return count_;
      }

      [[nodiscard]] const PromptBinding& operator[](std::size_t index) const noexcept {
        return entries_[index];
      }

      [[nodiscard]] const PromptBinding* begin() const noexcept {
        return entries_.data();
      }

      [[nodiscard]] const PromptBinding* end() const noexcept {
        return entries_.data() + count_;
      }

      // Equal when they bind the same keys, whatever the slots past them held.
      friend bool operator==(const PromptBindings& left, const PromptBindings& right) noexcept {
        return std::ranges::equal(left.view(), right.view());
      }

    private:
      ds::Array<PromptBinding, capacity> entries_{};
      std::size_t count_ = 0;
    };

    // `client.prompt`: the shell prompt as the shell draws it, or telar's own command editor.
    struct PromptConfiguration {
      static constexpr std::uint8_t default_max_lines = 12;
      static constexpr std::uint8_t maximum_max_lines = 64;

      PromptMode mode = PromptMode::classic;
      PromptMotion motion = PromptMotion::spring;
      PromptKeymap keymap = PromptKeymap::emacs;
      bool ghost = true;
      std::uint8_t max_lines = default_max_lines;
      PromptBindings bindings;

      bool operator==(const PromptConfiguration&) const = default;
    };

    struct SoundPolicy {
      bool enabled = true;
      bool ready = true;
      bool needs_input = true;
    };

    enum class NotificationDelivery : std::uint8_t {
      telar,
      system,
    };

    // How panes scroll: by pixels, a wheel notch settling in `wheel_ms`, with `overscan` views of
    // rows asked for around the shown one while it moves; and whether the separator of the command
    // being read stays on the top row.
    struct ScrollConfiguration {
      static constexpr std::uint16_t default_wheel_ms = 80;
      static constexpr std::uint16_t maximum_wheel_ms = 400;
      static constexpr float maximum_overscan = 4;

      bool smooth = true;
      std::uint16_t wheel_ms = default_wheel_ms;
      float overscan = 1;
      bool sticky_headers = true;
    };

    struct Configuration {
      static constexpr std::size_t maximum_editor_bytes = 4096;
      static constexpr std::size_t maximum_window_title_bytes = 128;
      static constexpr std::chrono::milliseconds default_blink_interval{600};
      static constexpr std::chrono::milliseconds minimum_blink_interval{100};
      static constexpr std::chrono::milliseconds maximum_blink_interval{5000};
      static constexpr float default_sidebar_width = 240;
      static constexpr float minimum_sidebar_width = 220;
      static constexpr float maximum_sidebar_width = 800;
      static constexpr float minimum_chrome_scale = 0.5F;
      static constexpr float maximum_chrome_scale = 2;
      static constexpr float maximum_padding = 256;
      static constexpr std::uint16_t minimum_fps = 30;
      static constexpr std::uint16_t maximum_fps = 240;
      static constexpr std::uint16_t default_fps = 60;
      static constexpr std::uint8_t default_background_blur = 20;
      static constexpr std::uint8_t maximum_background_blur = 255;

      FontConfiguration font;
      runtime::FixedText<maximum_editor_bytes> editor;
      runtime::FixedText<maximum_window_title_bytes> window_title;
      HistoryConfiguration history;
      PromptConfiguration prompt;
      SoundPolicy sound;
      NotificationDelivery notification_delivery = NotificationDelivery::telar;
      Theme theme;
      ThemeSelection themes;
      CursorShape cursor = CursorShape::block;
      ScrollConfiguration scroll;
      bool cursor_blink = true;
      std::chrono::milliseconds blink_interval = default_blink_interval;
      float background_opacity = 1;
      BackgroundOpacity opacity;
      std::uint8_t background_blur = default_background_blur;
      float padding_x = 0;
      float padding_y = 0;
      float chrome_scale = 1;
      float sidebar_width = default_sidebar_width;
      // `sidebar.width = "auto"`: the window fits the sidebar to its content when it opens, on a
      // reload and on a double click of its edge.
      bool sidebar_width_auto = true;
      std::uint16_t max_fps = 0;
      bool sidebar_visible = true;
      bool pane_gaps = true;
      ds::Option<bool> titlebar;
    };

  }
}
