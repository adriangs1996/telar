#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "window_status.hpp"
#include "key_bindings.hpp"
#include "ui/app/chrome/metrics_projection.hpp"
#include "ui/app/chrome/mode_bar/mode_projection.hpp"
#include "ui/app/panes/terminal/copy_controller.hpp"
#include "ui/kit/models/projection.hpp"
#include <QString>
#include <QVariantMap>
#include <cstddef>
#include <utility>

namespace telar::gui::qt {

  WindowStatus::WindowStatus(Store& store, CopyController& copy, KeyBindings& keys, QByteArray hostname, QObject* parent)
      : QObject(parent),
        store_(store),
        copy_(copy),
        keys_(keys),
        hostname_(std::move(hostname)) {
    connect(&keys_, &KeyBindings::prefixChanged, this, &WindowStatus::prefixChanged);
    connect(&keys_, &KeyBindings::prefixChanged, this, &WindowStatus::modeChanged);
    connect(&copy_, &CopyController::activeChanged, this, &WindowStatus::modeChanged);
  }

  void WindowStatus::clear() {
    error_.clear();
  }

  void WindowStatus::publishMetrics() {
    emit hostMetricsChanged();
  }

  void WindowStatus::report(const QString& message) {
    error_ = message;
    publish();
  }

  void WindowStatus::fail(const std::exception& error) {
    error_ = QString::fromUtf8(error.what());
    publish();
  }

  bool WindowStatus::connected() const {
    return store_.connection().ready();
  }

  QString WindowStatus::title() const {
    const auto title = application::window::title(store_.session(), {hostname_.constData(), static_cast<std::size_t>(hostname_.size())});

    return toQString(title.view());
  }

  bool WindowStatus::prefixPending() const noexcept {
    return keys_.prefixPending();
  }

  QVariantMap WindowStatus::mode() const {
    if (prefixPending()) {
      return statusModeRecord(application::status_bar::StatusMode::prefix, keys_.modeHints());
    }

    return statusModeRecord(copy_.active() ? application::status_bar::StatusMode::copy : application::status_bar::StatusMode::normal);
  }

  QVariantMap WindowStatus::hostMetrics() const {
    return metricsRecord(application::status_bar::metrics(store_.session()));
  }

  QString WindowStatus::tlsBadgeColor() const {
    const auto& proxy = store_.session().proxyStatus();
    if (!proxy.active && !proxy.system_trusted) {
      return {};
    }

    if (!proxy.active) {
      return QStringLiteral("yellow");
    }

    return proxy.scope == ProxyScope::wildcard ? QStringLiteral("red") : QStringLiteral("peach");
  }

  void WindowStatus::dismiss() {
    error_.clear();
    store_.sessionMut().dismissDiagnostic();
    store_.connectionMut().dismissError();
    publish();
  }

  void WindowStatus::publish() {
    auto& published = published_;
    auto title = this->title();
    if (title != published.title) {
      published.title = std::move(title);
      emit titleChanged();
    }

    auto error = this->error();
    auto tls_badge_color = tlsBadgeColor();
    const auto connected = this->connected();
    if (error != published.error || tls_badge_color != published.tls_badge_color || connected != published.connected) {
      published.error = std::move(error);
      published.tls_badge_color = std::move(tls_badge_color);
      published.connected = connected;
      emit diagnosticChanged();
    }

    copy_.publish();
  }

  QString WindowStatus::error() const {
    if (!error_.isEmpty()) {
      return error_;
    }

    return toQString(store_.session().error());
  }

}
