module;
#include "tbc/annotations.hpp"

export module telar.gui.presentation.history_inspection;

import std;

import telar.tbc;
import telar.gui.foundation.core;
import telar.gui.foundation.text;
import telar.gui.foundation.actions;

// Interface: presentation/mode_hints.cppm
export {
  namespace telar::gui {

    enum class StatusMode : std::uint8_t {
      normal,
      prefix,
      copy,
    };

    struct ModeHint {
      KeyChord key;
      std::string_view label;
    };

    template <typename Router>
    concept PrefixHintRouter = requires(const Router& router, const BindingAction& action) {
      { router.prefixedKeyForAction(action) } -> std::same_as<std::optional<KeyChord>>;
    };

    class ModeHints {
    public:
      static constexpr auto actions = std::to_array<std::pair<BindingActionKind, std::string_view>>({
          {BindingActionKind::split_horizontal, "split right"},
          {BindingActionKind::split_vertical, "split down"},
          {BindingActionKind::new_tab, "new tab"},
          {BindingActionKind::new_workspace, "new workspace"},
          {BindingActionKind::rename_tab, "rename tab"},
          {BindingActionKind::rename_workspace, "rename workspace"},
          {BindingActionKind::close_pane, "close pane"},
          {BindingActionKind::copy_mode, "copy mode"},
      });
      static constexpr std::size_t capacity = actions.size();

      // Stays here: generic over the caller's router.
      template <PrefixHintRouter Router>
      // The labels of the hints a router binds are literals.
      [[nodiscard]] TBC_GENERIC static tbc::view<ModeHints, tbc::lt::static_storage> resolve(const Router& router) noexcept {
        ModeHints result;

        for (const auto& [action, label] : actions) {
          if (const auto key = router.prefixedKeyForAction({.kind = action})) {
            result.append({.key = *key, .label = label});
          }
        }

        return result;
      }

      // The hints view their labels, region `a`.
      void append(tbc::view<ModeHint, tbc::lt::a> hint) noexcept;

      [[nodiscard]] tbc::view<std::span<const ModeHint>, tbc::lt::a> items() const noexcept;

    private:
      tbc::view<std::array<ModeHint, capacity>, tbc::lt::a> hints_{};
      std::size_t count_ = 0;
    };

  }
}

// Interface: presentation/mode_key_label.cppm
export {
  namespace telar::gui {

    struct ModeKeyLabel {
      static constexpr std::size_t capacity = 48;
      using Text = BoundedText<capacity>;

      [[nodiscard]] static Text format(KeyChord key);

    private:
      [[nodiscard]] static std::string_view name(KeyChord::Key key) noexcept;
    };

  }
}

// Interface: presentation/mode_bar_labels.cppm
export {
  namespace telar::gui {

    struct ModeBarHint {
      static constexpr std::size_t word_capacity = 32;
      ModeKeyLabel::Text key;
      BoundedText<word_capacity> word;
    };

    // What the bar shows while a mode holds the keyboard: the mode's name and the keys it answers.
    class ModeBarLabels {
    public:
      static constexpr auto copy_hints = std::to_array<std::pair<std::string_view, std::string_view>>({
          {"h j k l", "move"},
          {"v", "select"},
          {"V", "lines"},
          {"/", "search"},
          {"y", "copy"},
          {"o", "open"},
          {"q", "exit"},
      });
      static constexpr std::string_view cancel_key = "Esc";
      static constexpr std::string_view cancel_word = "cancel";
      static constexpr std::size_t capacity = std::max(copy_hints.size(), 1 + ModeHints::capacity);

      [[nodiscard]] static ModeBarLabels resolve(StatusMode mode, const ModeHints& hints);

      [[nodiscard]] std::string_view title() const noexcept;

      [[nodiscard]] std::span<const ModeBarHint> hints() const noexcept;

    private:
      void append(std::string_view key, std::string_view word);

      std::string_view title_;
      std::array<ModeBarHint, capacity> hints_{};
      std::size_t count_ = 0;
    };

  }
}

// Interface: presentation/workspace_mark.cppm
export {
  namespace telar::gui {

    struct WorkspaceMark {
      static constexpr auto hues = std::to_array<PaletteRole>({PaletteRole::red, PaletteRole::peach, PaletteRole::yellow, PaletteRole::green, PaletteRole::teal, PaletteRole::blue, PaletteRole::mauve});

      Utf8Scalar initial;
      PaletteRole hue = hues.front();

      [[nodiscard]] static WorkspaceMark resolve(std::string_view name);

    private:
      [[nodiscard]] static std::uint32_t hash(std::string_view name) noexcept;
    };

  }
}
