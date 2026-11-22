// The icons the window draws beside what an editor shows: a file's by its name, a folder's, and
// a completion's by its kind, as glyphs of the bundled Symbols Nerd Font with a role of the
// window's palette to color them. Neovim's own interfaces draw the same glyphs with the same
// font, so a list of the window's reads as theirs does.
export module telar.gui.foundation.icons;

import std;

export {
  namespace telar::gui::inline foundation::inline icons {

    // A color of the window's palette an icon is drawn in.
    enum class IconTone : std::uint8_t {
      blue,
      teal,
      green,
      grey,
      peach,
      mauve,
      red,
      yellow,
    };

    struct GlyphIcon {
      char32_t glyph = 0;
      IconTone tone = IconTone::grey;

      friend constexpr bool operator==(const GlyphIcon&, const GlyphIcon&) = default;
    };

    // The icon of a file by its name, or by the last part of a path: a name telar knows, such as
    // `Makefile`, else its longest extension it knows, else a plain file's. Case does not count.
    [[nodiscard]] GlyphIcon fileIcon(std::string_view name) noexcept;

    [[nodiscard]] GlyphIcon directoryIcon() noexcept;

    // The icon of a completion's kind: a kind of the language server protocol by its name, as
    // `Function`, or Vim's own letter, as `f`. A kind telar does not know is text's.
    [[nodiscard]] GlyphIcon kindIcon(std::string_view kind) noexcept;

    // The name of the palette's role, as the window's colors call it.
    [[nodiscard]] std::string_view toneName(IconTone tone) noexcept;

    // Every icon the tables hold, for a check that the bundled font draws them all.
    [[nodiscard]] std::span<const GlyphIcon> everyIcon() noexcept;

  }
}
