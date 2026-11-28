module telar.gui.ui.app;

import std;
import telar.gui.qt;
import telar.gui.ui.app.chrome;
import telar.gui.ui.app.chrome.mode_bar;
import telar.gui.ui.app.panes.terminal;
import telar.gui.ui.kit.models;

namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

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
    hostMetricsChanged();
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
      return u"yellow"_s;
    }

    return proxy.scope == ProxyScope::wildcard ? u"red"_s : u"peach"_s;
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
      titleChanged();
    }

    auto error = this->error();
    auto tls_badge_color = tlsBadgeColor();
    const auto connected = this->connected();
    if (error != published.error || tls_badge_color != published.tls_badge_color || connected != published.connected) {
      published.error = std::move(error);
      published.tls_badge_color = std::move(tls_badge_color);
      published.connected = connected;
      diagnosticChanged();
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
