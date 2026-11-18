module telar.gui.foundation.text;

namespace telar::gui::inline foundation::inline text {

  TextFit::Prefixes TextFit::collectPrefixes(std::string_view text) {
    GraphemeCursor cursor{text};
    Prefixes result;
    std::size_t bytes = 0;

    while (const auto cluster = cursor.next()) {
      ++result.graphemes;
      bytes += cluster->size();
      if (bytes <= maximum_bytes - ellipsis.size()) {
        result.bytes.atMut(++result.stored) = bytes;
      }
    }

    return result;
  }

}
