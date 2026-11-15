module telar.gui.text.json_unsigned_integer;

import telar.gui.text.bounded_editor;

namespace telar::gui {

  TextFit::Prefixes TextFit::collectPrefixes(std::string_view text) {
    GraphemeCursor cursor{text};
    Prefixes result;
    std::size_t bytes = 0;

    while (const auto cluster = cursor.next()) {
      ++result.graphemes;
      bytes += cluster->size();
      if (bytes <= maximum_bytes - ellipsis.size()) {
        result.bytes[++result.stored] = bytes;
      }
    }

    return result;
  }

}
