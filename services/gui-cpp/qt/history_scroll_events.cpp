#include "history_scroll_events.hpp"
#include "pointer_dispatcher.hpp"
#include <QCoreApplication>
#include <QtCore/qtypes.h>
#include <cstddef>

namespace telar::gui::qt {

HistoryScrollEvents::HistoryScrollEvents(PointerDispatcher &receiver)
    : receiver_(receiver) {}

HistoryScrollEvents::~HistoryScrollEvents() {
  if (installed_ && QCoreApplication::instance() != nullptr) {
    QCoreApplication::instance()->removeNativeEventFilter(this);
  }
}

void HistoryScrollEvents::setActive(bool active) {
  if (active == installed_) {
    return;
  }

  installed_ = active;
  if (active) {
    QCoreApplication::instance()->installNativeEventFilter(this);
  } else {
    QCoreApplication::instance()->removeNativeEventFilter(this);
  }
}

bool HistoryScrollEvents::nativeEventFilter(const QByteArray &event_type, void *message, [[maybe_unused]] qintptr *result) {
  return receiver_.handleNativeScroll({event_type.constData(), static_cast<std::size_t>(event_type.size())}, message);
}

}
