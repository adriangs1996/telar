module telar.wire.content;

import std;
import telar.wire.vocabulary;

// The owned header declares these in the global module, so their definitions belong to it too.
extern "C++" {
namespace telar {

  void SearchPaneRows::validate() const {
    if (last_row < first_row) {
      throw EncodingError{"Search rows end before they begin"};
    }
  }

  void PaneDocument::validate() const {
    if (size > max_size || offset > size || bytes.size() > size - offset || (size != 0 && bytes.empty() && (offset != size || id == 0))) {
      throw EncodingError{"Invalid document part"};
    }

    if ((id == 0 && (generation != 0 || first_row != 0 || rows != 0)) || (id != 0 && size != 0 && rows == 0)) {
      throw EncodingError{"Invalid document rows"};
    }
  }

  void PaneRows::validate() const {
    const auto count = static_cast<std::uint32_t>(cols) * rows;
    if (rows > ReadPaneRows::maximum_rows || count > 130359 || (rows != 0 && cols == 0)) {
      throw EncodingError{"Invalid pane rows header"};
    }

    if (rows == 0) {
      if (text_metadata || !cells.empty()) {
        throw EncodingError{"Empty pane rows carry cells"};
      }

      return;
    }

    if (!text_metadata) {
      throw EncodingError{"Pane rows without metadata"};
    }

    text_metadata->validate(cols, rows);
    auto cells_reader = reader();

    while (cells_reader.next()) {
    }
  }

}
}
