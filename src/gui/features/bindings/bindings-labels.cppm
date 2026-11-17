// How the chrome names a key or a prefixed chord: Ctrl+ and words on a PC, the glyphs on a Mac.
export module telar.gui.features.bindings:labels;

import std;

import telar.gui.foundation.actions;
import telar.gui.foundation.text;

// Interface: input/key_label.cppm
export {
  namespace telar::gui::features::bindings {

    enum class KeyLabelStyle : std::uint8_t {
      pc,
      mac,
    };

    class KeyLabel {
    public:
      static constexpr std::size_t capacity = 64;
      using Text = BoundedText<capacity>;

      [[nodiscard]] static Text chord(std::optional<KeyChord> prefix, KeyChord key, KeyLabelStyle style);

    private:
      struct ModifierLabel {
        KeyChord::Modifier modifier;
        std::string_view pc;
        std::string_view mac;
      };

      struct KeyName {
        KeyChord::Key key;
        std::string_view pc;
        std::string_view mac;
      };

      static void append(Text& text, KeyChord key, KeyLabelStyle style);
    };

  }
}
