#include "application/dependencies.hpp"
#include "qt/clipboard_images.hpp"
#include <QByteArray>
#include <QByteArrayView>
#include <QClipboard>
#include <QCoreApplication>
#include <QCryptographicHash>
#include <QElapsedTimer>
#include <QFile>
#include <QGuiApplication>
#include <QImage>
#include <QIODevice>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMimeData>
#include <QObject>
#include <QQuickWindow>
#include <QString>
#include <QtCore/qstringliteral.h>
#include <QtCore/qconfig.h>
#include <QStringList>
#include <QTimer>
#include <QtCore/qtypes.h>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <utility>

namespace {

using namespace telar::gui;
using namespace telar::gui::qt;

enum class Argument : std::uint8_t { program, expected, output, count };

QString digest(QByteArrayView bytes) {
  return QString::fromLatin1(QCryptographicHash::hash(bytes, QCryptographicHash::Sha256).toHex());
}

QString imageDigest(const QImage &image) {
  return digest(QByteArrayView{std::span{image.constBits(), static_cast<std::size_t>(image.sizeInBytes())}});
}

int baseline(const QString &path) {
  QQuickWindow window;
  window.setTitle(QStringLiteral("Owned clipboard baseline"));
  constexpr int width = 500;
  constexpr int height = 400;
  window.resize(width, height);
  window.show();
  constexpr std::chrono::milliseconds lifetime{250};
  QTimer::singleShot(lifetime, &window, [path] {
    const QJsonObject record{{QStringLiteral("outcome"), QStringLiteral("baseline")}, {QStringLiteral("snapshot_us"), 0}};
    const auto bytes = QJsonDocument{record}.toJson(QJsonDocument::Indented);
    QFile output{path};
    const bool written = output.open(QIODevice::WriteOnly) && output.write(bytes) == bytes.size();
    QCoreApplication::exit(written ? 0 : 1);
  });

  return QCoreApplication::exec();
}

class ClipboardProbe final : public QObject {
public:
  ClipboardProbe(QString expected, QString output)
      : expected_(std::move(expected)),
        output_(std::move(output)),
        worker_(memory_) {
    connect(&worker_, &ClipboardImages::ready, this, &ClipboardProbe::completed);
    connect(&ticker_, &QTimer::timeout, this, &ClipboardProbe::tick);
    connect(&watchdog_, &QTimer::timeout, this, [this] { write(QStringLiteral("ClipboardProbeDeadline")); });
  }

  ~ClipboardProbe() override = default;
  ClipboardProbe(const ClipboardProbe &) = delete;
  ClipboardProbe &operator=(const ClipboardProbe &) = delete;
  ClipboardProbe(ClipboardProbe &&) = delete;
  ClipboardProbe &operator=(ClipboardProbe &&) = delete;

  int run() {
    window_.setTitle(QStringLiteral("Owned clipboard receiver"));
    constexpr int width = 500;
    constexpr int height = 400;
    window_.resize(width, height);
    window_.show();
    constexpr std::chrono::milliseconds poll{10};
    constexpr std::chrono::seconds deadline{15};
    ticker_.start(poll);
    watchdog_.setSingleShot(true);
    watchdog_.start(deadline);

    return QCoreApplication::exec();
  }

private:
  void tick() {
    ++heartbeats_;
    if (started_ || !window_.isActive()) {
      return;
    }

    const auto *const board = QGuiApplication::clipboard();
    const auto *const mime = board != nullptr ? board->mimeData() : nullptr;
    if (board == nullptr || board->ownsClipboard() || mime == nullptr || !mime->hasFormat(QStringLiteral("image/png"))) {
      return;
    }

    started_ = true;
    initial_heartbeat_ = heartbeats_;
    elapsed_.start();
    worker_.capture({.source = {.machine = {.slot = 0, .generation = 0}, .generation = 1}, .runtime_generation = 1, .attachment_generation = 1, .request = {.capture = {.id = 1, .target = {.pane_id = 1, .pane_generation = 1}}}});
    snapshot_us_ = std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::nanoseconds{elapsed_.nsecsElapsed()}).count();
  }

  void completed() {
    result_ = worker_.takeResult();
    QTimer::singleShot(std::chrono::milliseconds::zero(), this, &ClipboardProbe::finish);
  }

  void finish() {
    if (!result_) {
      write(QStringLiteral("MissingClipboardCompletion"));

      return;
    }

    const auto outcome = result_->error.isEmpty() && result_->capture && result_->preview ? QStringLiteral("ok") : result_->error;
    write(outcome);
  }

  void write(const QString &outcome) {
    ticker_.stop();
    watchdog_.stop();
    QJsonObject record{{QStringLiteral("outcome"), outcome}, {QStringLiteral("expected"), expected_}, {QStringLiteral("snapshot_us"), snapshot_us_}, {QStringLiteral("elapsed_ms"), started_ ? elapsed_.elapsed() : 0}, {QStringLiteral("heartbeats"), static_cast<qint64>(heartbeats_ - initial_heartbeat_)}, {QStringLiteral("platform"), QGuiApplication::platformName()}, {QStringLiteral("qt_version"), QStringLiteral(QT_VERSION_STR)}};
    if (result_ && result_->capture) {
      record.insert(QStringLiteral("png_sha256"), digest(QByteArrayView{result_->capture->png.unsignedBytes()}));
      record.insert(QStringLiteral("png_bytes"), static_cast<qint64>(result_->capture->png.size()));
      record.insert(QStringLiteral("width"), static_cast<qint64>(result_->capture->width));
      record.insert(QStringLiteral("height"), static_cast<qint64>(result_->capture->height));
    }

    if (result_ && result_->preview) {
      record.insert(QStringLiteral("thumbnail_sha256"), imageDigest(result_->preview->thumbnail));
      record.insert(QStringLiteral("full_sha256"), imageDigest(result_->preview->full));
    }

    const auto bytes = QJsonDocument{record}.toJson(QJsonDocument::Indented);
    QFile output{output_};
    constexpr qint64 maximum_snapshot_us = 500000;
    const bool accepted = outcome == expected_ && snapshot_us_ < maximum_snapshot_us;
    const bool written = output.open(QIODevice::WriteOnly) && output.write(bytes) == bytes.size();
    QCoreApplication::exit(accepted && written ? 0 : 1);
  }

  ApplicationAllocator memory_;
  QString expected_;
  QString output_;
  QQuickWindow window_;
  QTimer ticker_;
  QTimer watchdog_;
  QElapsedTimer elapsed_;
  std::uint64_t heartbeats_ = 0;
  std::uint64_t initial_heartbeat_ = 0;
  qint64 snapshot_us_ = 0;
  bool started_ = false;
  std::optional<ClipboardImageResult> result_;
  ClipboardImages worker_;
};

}

int main(int argc, char **argv) {
  const QGuiApplication application{argc, argv};
  const auto arguments = QCoreApplication::arguments();
  if (arguments.size() != static_cast<int>(Argument::count) || !QGuiApplication::platformName().startsWith(QStringLiteral("wayland"))) {
    return 1;
  }

  if (arguments.at(static_cast<int>(Argument::expected)) == QStringLiteral("baseline")) {
    return baseline(arguments.at(static_cast<int>(Argument::output)));
  }

  ClipboardProbe probe{arguments.at(static_cast<int>(Argument::expected)), arguments.at(static_cast<int>(Argument::output))};

  return probe.run();
}
