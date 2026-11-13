#pragma once

#include <QByteArray>
#include <QHash>
#include <QtCore/qtenvironmentvariables.h>
#include <cstddef>
#include <optional>
#include <string_view>

namespace telar::gui::platform {

class ProcessEnvironment {
public:
  [[nodiscard]] std::optional<std::string_view> operator()(const char *name) const {
    const QByteArray key{name};
    if (const auto found = values_.constFind(key); found != values_.cend()) {
      return view(found.value());
    }

    const auto value = qgetenv(name);
    if (value.isNull()) {
      return {};
    }

    return view(values_.insert(key, value).value());
  }

private:
  [[nodiscard]] static std::string_view view(const QByteArray &value) noexcept {
    return {value.constData(), static_cast<std::size_t>(value.size())};
  }

  mutable QHash<QByteArray, QByteArray> values_;
};

}
