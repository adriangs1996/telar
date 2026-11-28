export module telar.gui.ui.kit.process:environment;

import std;
import telar.gui.qt;
import telar.base.ds;

export namespace telar::gui::qt {

  class ProcessEnvironment {
  public:
    [[tbc::hot_path]] [[nodiscard]] inline ds::Option<std::string_view> operator()(const char* name) const {
      const QByteArray key{name};
      if (const auto found = values_.entries.constFind(key); found != values_.entries.cend()) {
        return view(found.value());
      }

      const auto value = qgetenv(name);
      if (value.isNull()) {
        return {};
      }

      return view(values_.entries.insert(key, value).value());
    }

  private:
    [[tbc::hot_path]] [[nodiscard]] inline static std::string_view view(const QByteArray& value) noexcept {
      return {value.constData(), static_cast<std::size_t>(value.size())};
    }

    struct [[tbc::shared]] Values {
      QHash<QByteArray, QByteArray> entries;
    };

    mutable Values values_;
  };

}
