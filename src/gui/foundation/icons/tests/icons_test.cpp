import std;
import telar.testing;
import telar.gui.foundation.icons;

namespace {

  using telar::testing::check;
  using namespace telar::gui;

  // A file is known by its name before its extension, whatever the case of either, and a
  // path counts by its last part.
  void filesByNameThenExtension() {
    const auto plain = fileIcon("notes.unknown-extension");

    check(fileIcon("main.rs") != plain && fileIcon("main.rs") == fileIcon("lib.RS"), "an extension, in any case");
    check(fileIcon("src/runtime/main.rs") == fileIcon("main.rs"), "a path, by its last part");
    check(fileIcon("Makefile") != plain && fileIcon("Makefile") == fileIcon("makefile"), "a name of its own");
    check(fileIcon("CMakeLists.txt") != fileIcon("notes.txt"), "a name before its extension");
    check(fileIcon("archive.tar.gz") != plain, "the longest extension known");
    check(fileIcon(".gitignore") != plain && fileIcon(".bashrc-like") == plain, "a dotfile by its name, not as an extension");
    check(fileIcon("") == plain && fileIcon("dir/") == plain && fileIcon("trailing.") == plain, "nothing to know it by");
    check(directoryIcon() != plain, "a folder is not a file");
  }

  // A completion's kind by the protocol's name or Vim's letter; one telar does not know is text.
  void kindsByNameOrLetter() {
    check(kindIcon("Function") == kindIcon("function") && kindIcon("f") == kindIcon("Function"), "a function, either way");
    check(kindIcon("v") == kindIcon("Variable") && kindIcon("m") == kindIcon("Field"), "Vim's letters");
    check(kindIcon("Method") != kindIcon("Variable"), "kinds apart");
    check(kindIcon("Something new") == kindIcon("Text") && kindIcon("") == kindIcon("Text"), "an unknown kind");
  }

  // Every icon is a glyph of the private use areas Nerd Fonts fill, colored by a palette role.
  void everyIconIsAGlyphWithARole() {
    const auto icons = everyIcon();

    check(icons.size() > 200, "the tables are there");
    for (const auto icon : icons) {
      const bool private_use = (icon.glyph >= 0xE000 && icon.glyph <= 0xF8FF) || (icon.glyph >= 0xF0000 && icon.glyph <= 0xFFFFD);

      check(private_use, "a Nerd Font glyph");
      check(!toneName(icon.tone).empty(), "a role of the palette");
    }
  }

  const telar::testing::Case case_files{"icons.files_by_name_then_extension", filesByNameThenExtension};
  const telar::testing::Case case_kinds{"icons.kinds_by_name_or_letter", kindsByNameOrLetter};
  const telar::testing::Case case_every{"icons.every_icon_is_a_glyph_with_a_role", everyIconIsAGlyphWithARole};

}
