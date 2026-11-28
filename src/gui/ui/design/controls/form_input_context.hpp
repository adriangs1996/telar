#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <QString>
#include <algorithm>
#include <optional>
#include <utility>

#pragma once

import telar.base.ds;

namespace telar::gui::qt {

  struct FormInputContext {
    struct Replacement {
      int first = 0;
      int last = 0;
    };

    QString text;
    int cursor = 0;
    int anchor = 0;

    [[nodiscard]] static FormInputContext capture(QString text, int cursor, int anchor, ds::Option<Replacement> replacement = ds::none) {
      FormInputContext result{.text = std::move(text), .cursor = cursor, .anchor = anchor};

      if (replacement) {
        result.text.remove(replacement->first, replacement->last - replacement->first);
        result.cursor = replacement->first;
        result.anchor = replacement->first;
      }

      return result;
    }

    [[nodiscard]] QString beforeCursor() const {
      return text.first(cursor);
    }

    [[nodiscard]] QString afterCursor() const {
      return text.sliced(cursor);
    }

    [[nodiscard]] QString selectedText() const {
      const auto first = std::min(cursor, anchor);

      return text.mid(first, std::max(cursor, anchor) - first);
    }
  };

}
