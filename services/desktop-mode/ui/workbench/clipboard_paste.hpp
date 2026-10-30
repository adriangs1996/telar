#pragma once

#include "telar_client/serializers/telar_protocol.hpp"
#include <QMimeData>
#include <QPointer>
#include <QStringList>
#include <optional>

namespace workbench {

struct ClipboardPaste {
  QString text;
  QStringList available;
};

// A listing request must never materialize representations. Own values before
// invoking the consumer: lazy platform reads can invalidate the source object.
inline std::optional<ClipboardPaste> readClipboardPaste(const QMimeData *source, bool listing_only) {
  const QPointer<const QMimeData> data{source};
  if (!data) {
    return ClipboardPaste{};
  }
  ClipboardPaste result;
  const auto formats = data->formats();
  if (!data) {
    return std::nullopt;
  }
  for (const auto &format : formats) {
    if (!format.isEmpty() && format.size() <= 256) {
      result.available.push_back(format);
      if (result.available.size() == 16) {
        break;
      }
    }
  }
  if (!listing_only) {
    result.text = data->text();
    if (!data || static_cast<std::size_t>(result.text.size()) > telar::clipboard_content_limit) {
      return std::nullopt;
    }
  }
  return result;
}

}
