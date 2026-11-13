#include <QByteArray>
#include <QClipboard>
#include <QCoreApplication>
#include <QFile>
#include <QGuiApplication>
#include <QIODevice>
#include <QKeyEvent>
#include <QMetaType>
#include <QMimeData>
#include <QObject>
#include <QQuickWindow>
#include <QString>
#include <QtCore/qstringliteral.h>
#include <QStringList>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qnamespace.h>
#include <QTimer>
#include <QVariant>
#include <chrono>
#include <cstdint>
#include <memory>
#include <thread>
#include <utility>

namespace {

enum class Argument : std::uint8_t { program, input, ready, delay, count };

class ProviderWindow final : public QQuickWindow {
public:
  ProviderWindow() = default;
  ~ProviderWindow() override = default;
  ProviderWindow(const ProviderWindow &) = delete;
  ProviderWindow &operator=(const ProviderWindow &) = delete;
  ProviderWindow(ProviderWindow &&) = delete;
  ProviderWindow &operator=(ProviderWindow &&) = delete;

  [[nodiscard]] bool receivedInput() const noexcept {
    return received_input_;
  }

protected:
  void keyPressEvent(QKeyEvent *event) override {
    received_input_ = received_input_ || event->key() == Qt::Key_F24;
    event->accept();
  }

private:
  bool received_input_ = false;
};

class ProviderData final : public QMimeData {
public:
  ProviderData(QByteArray bytes, std::chrono::milliseconds delay)
      : bytes_(std::move(bytes)),
        delay_(delay) {}
  ~ProviderData() override = default;
  ProviderData(const ProviderData &) = delete;
  ProviderData &operator=(const ProviderData &) = delete;
  ProviderData(ProviderData &&) = delete;
  ProviderData &operator=(ProviderData &&) = delete;

  [[nodiscard]] QStringList formats() const override {
    return {QStringLiteral("image/png")};
  }

protected:
  [[nodiscard]] QVariant retrieveData(const QString &format, [[maybe_unused]] QMetaType requested) const override {
    if (format != QStringLiteral("image/png")) {
      return {};
    }

    std::this_thread::sleep_for(delay_);

    return bytes_;
  }

private:
  QByteArray bytes_;
  std::chrono::milliseconds delay_;
};

}

int main(int argc, char **argv) {
  const QGuiApplication application{argc, argv};
  const auto arguments = QCoreApplication::arguments();
  if (arguments.size() != static_cast<int>(Argument::count) || (!QGuiApplication::platformName().startsWith(QStringLiteral("wayland")) && QGuiApplication::platformName() != QStringLiteral("xcb"))) {
    return 1;
  }

  QFile image{arguments.at(static_cast<int>(Argument::input))};
  if (!image.open(QIODevice::ReadOnly)) {
    return 1;
  }

  bool valid = false;
  const auto delay = arguments.at(static_cast<int>(Argument::delay)).toInt(&valid);
  constexpr int maximum_delay_ms = 10000;
  if (!valid || delay < 0 || delay > maximum_delay_ms) {
    return 1;
  }

  auto bytes = image.readAll();
  if (image.error() != QFile::NoError) {
    return 1;
  }

  ProviderWindow window;
  window.setTitle(QStringLiteral("Owned clipboard provider"));
  constexpr int width = 400;
  constexpr int height = 300;
  window.resize(width, height);
  window.show();
  if (QGuiApplication::platformName() == QStringLiteral("xcb")) {
    window.requestActivate();
  }

  QTimer readiness;
  QObject::connect(&readiness, &QTimer::timeout, &application, [&] {
    if (!window.isActive()) {
      return;
    }

    if (!window.receivedInput() && QGuiApplication::platformName().startsWith(QStringLiteral("wayland"))) {
      QFile mapped{arguments.at(static_cast<int>(Argument::ready)) + QStringLiteral(".mapped")};
      if (!mapped.exists() && (!mapped.open(QIODevice::WriteOnly) || mapped.write(QByteArrayLiteral("mapped")) <= 0)) {
        QCoreApplication::exit(1);
      }

      return;
    }

    readiness.stop();
    auto data = std::make_unique<ProviderData>(std::move(bytes), std::chrono::milliseconds{delay});
    QGuiApplication::clipboard()->setMimeData(data.release());
    QFile ready{arguments.at(static_cast<int>(Argument::ready))};
    if (!QGuiApplication::clipboard()->ownsClipboard() || !ready.open(QIODevice::WriteOnly) || ready.write(QByteArrayLiteral("ready")) <= 0) {
      QCoreApplication::exit(1);
    }
  });
  constexpr std::chrono::milliseconds poll{10};
  readiness.start(poll);
  constexpr std::chrono::seconds watchdog{60};
  QTimer::singleShot(watchdog, &application, [] { QCoreApplication::exit(1); });

  return QCoreApplication::exec();
}
