export module telar.gui.ui.design.controls:form_input_context;

import std;
import telar.gui.qt;
import telar.base.ds;

export namespace telar::gui::qt {

  struct FormInputContext {
    struct Replacement {
      int first = 0;
      int last = 0;
    };

    QString text;
    int cursor = 0;
    int anchor = 0;

    [[tbc::hot_path]] [[nodiscard]] inline static FormInputContext capture(QString text, int cursor, int anchor, ds::Option<Replacement> replacement = ds::none) {
      FormInputContext result{.text = std::move(text), .cursor = cursor, .anchor = anchor};

      if (replacement) {
        result.text.remove(replacement->first, replacement->last - replacement->first);
        result.cursor = replacement->first;
        result.anchor = replacement->first;
      }

      return result;
    }

    [[tbc::hot_path]] [[nodiscard]] inline QString beforeCursor() const {
      return text.first(cursor);
    }

    [[tbc::hot_path]] [[nodiscard]] inline QString afterCursor() const {
      return text.sliced(cursor);
    }

    [[tbc::hot_path]] [[nodiscard]] inline QString selectedText() const {
      const auto first = std::min(cursor, anchor);

      return text.mid(first, std::max(cursor, anchor) - first);
    }
  };

}
