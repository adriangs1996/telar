export module telar.gui.foundation.forms:suggestion_preview;

import std;

import telar.gui.foundation.core;
import telar.gui.foundation.terminal;
import telar.gui.foundation.text;
import telar.base.ds;

// Interface: presentation/suggestion_preview.cppm
export {
  namespace telar::gui::inline foundation::inline forms {

    struct SuggestionPreviewLine {
      std::string_view text;
      Rect bounds;
      bool shortened = false;
    };

    class SuggestionPreview {
    public:
      static constexpr std::string_view shortened_message = "Preview shortened. Review the full command after pasting.";

      SuggestionPreview(std::string_view text, Rect bounds, const FontGrid& grid);

      [[nodiscard]] ds::Option<SuggestionPreviewLine> next();

    private:
      [[nodiscard]] static std::uint16_t columns(Rect bounds, std::uint16_t width);

      Rect bounds_;
      float line_height_;
      float y_;
      WrappedLines lines_;
      bool finished_ = false;
    };

  }
}
