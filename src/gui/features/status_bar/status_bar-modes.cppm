module;
#include "tbc/annotations.hpp"

// The mode bar's words: the mode that holds the keyboard, the keys it answers and the prefix
// bindings it hints at.
export module telar.gui.features.status_bar:modes;

import std;
import telar.tbc;

import telar.gui.foundation.actions;
import telar.gui.foundation.core;
import telar.gui.foundation.text;
import telar.base.ds;

// Interface: presentation/mode_hints.cppm
export {
  namespace telar::gui::features::status_bar {

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
      { router.prefixedKeyForAction(action) } -> std::same_as<ds::Option<KeyChord>>;
    };

    class ModeHints {
    public:
      using ActionHint = std::pair<BindingActionKind, std::string_view>;
      static constexpr auto actions = ds::Array<ActionHint, 9>{
          ActionHint{BindingActionKind::split_horizontal, "split right"},
          ActionHint{BindingActionKind::split_vertical, "split down"},
          ActionHint{BindingActionKind::new_tab, "new tab"},
          ActionHint{BindingActionKind::new_editor, "new editor"},
          ActionHint{BindingActionKind::new_workspace, "new workspace"},
          ActionHint{BindingActionKind::rename_tab, "rename tab"},
          ActionHint{BindingActionKind::rename_workspace, "rename workspace"},
          ActionHint{BindingActionKind::close_pane, "close pane"},
          ActionHint{BindingActionKind::copy_mode, "copy mode"},
      };
      static constexpr std::size_t capacity = actions.size();

      // Stays here: generic over the caller's router.
      template <PrefixHintRouter Router>
      // The labels of the hints a router binds are literals.
      [[nodiscard]] TBC_GENERIC static tbc::val_static<ModeHints> resolve(const Router& router) noexcept {
        ModeHints result;

        for (const auto& [action, label] : actions) {
          if (const auto key = router.prefixedKeyForAction({.kind = action})) {
            result.append({.key = *key, .label = label});
          }
        }

        return result;
      }

      // The hints view their labels, region `a`.
      void append(tbc::val_a<ModeHint> hint) noexcept;

      [[nodiscard]] tbc::val_a<std::span<const ModeHint>> items() const noexcept;

    private:
      tbc::val_a<ds::Array<ModeHint, capacity>> hints_{};
      std::size_t count_ = 0;
    };

  }
}

// Interface: presentation/mode_key_label.cppm
export {
  namespace telar::gui::features::status_bar {

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
  namespace telar::gui::features::status_bar {

    struct ModeBarHint {
      static constexpr std::size_t word_capacity = 32;
      ModeKeyLabel::Text key;
      BoundedText<word_capacity> word;
    };

    // What the bar shows while a mode holds the keyboard: the mode's name and the keys it answers.
    class ModeBarLabels {
    public:
      struct KeyHint {
        std::string_view key;
        std::string_view word;
      };

      static constexpr auto copy_hints = ds::Array<KeyHint, 7>{
          KeyHint{.key = "h j k l", .word = "move"},
          KeyHint{.key = "v", .word = "select"},
          KeyHint{.key = "V", .word = "lines"},
          KeyHint{.key = "/", .word = "search"},
          KeyHint{.key = "y", .word = "copy"},
          KeyHint{.key = "o", .word = "open"},
          KeyHint{.key = "q", .word = "exit"},
      };
      static constexpr std::string_view cancel_key = "Esc";
      static constexpr std::string_view cancel_word = "cancel";
      static constexpr std::size_t capacity = std::max(copy_hints.size(), 1 + ModeHints::capacity);

      [[nodiscard]] static ModeBarLabels resolve(StatusMode mode, const ModeHints& hints);

      [[nodiscard]] std::string_view title() const noexcept;

      [[nodiscard]] std::span<const ModeBarHint> hints() const noexcept;

    private:
      void append(KeyHint hint);

      std::string_view title_;
      ds::Array<ModeBarHint, capacity> hints_{};
      std::size_t count_ = 0;
    };

  }
}
