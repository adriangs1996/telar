module telar.wire.nvim;

import std;
import telar.wire.vocabulary;

namespace telar {

  void NvimGrid::validate() const {
    const auto cells = std::uint64_t{columns} * rows;
    std::uint64_t end = 0;

    for (const auto& span : spans) {
      // Spans come in order and stay inside the grid, so a client copies them without checking.
      if (span.start < end || span.count > cells || span.start > cells - span.count) {
        throw EncodingError{"A span lies outside its grid"};
      }

      end = std::uint64_t{span.start} + span.count;
    }

    for (const auto& scroll : scrolls) {
      if (scroll.top >= scroll.bottom || scroll.bottom > rows || scroll.left >= scroll.right || scroll.right > columns) {
        throw EncodingError{"A scroll lies outside its grid"};
      }
    }
  }

}
