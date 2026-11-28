#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <QByteArray>
#include <QHash>
#include <QtCore/qtenvironmentvariables.h>
#include <cstddef>
#include <optional>
#include <string_view>

#pragma once

import telar.base.ds;

namespace telar::gui::qt {

  class ProcessEnvironment {
  public:
    [[nodiscard]] ds::Option<std::string_view> operator()(const char* name) const {
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
    [[nodiscard]] static std::string_view view(const QByteArray& value) noexcept {
      return {value.constData(), static_cast<std::size_t>(value.size())};
    }

    struct [[tbc::shared]] Values {
      QHash<QByteArray, QByteArray> entries;
    };

    mutable Values values_;
  };

}
