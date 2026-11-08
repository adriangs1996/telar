#include "application/dependencies.hpp"
#include "qt/clipboard_images.hpp"
#include <QByteArray>
#include <QByteArrayView>
#include <QClipboard>
#include <QCoreApplication>
#include <QCryptographicHash>
#include <QElapsedTimer>
#include <QFile>
#include <QFuture>
#include <QGuiApplication>
#include <QIODevice>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QKeyEvent>
#include <QMimeData>
#include <QObject>
#include <QQuickWindow>
#include <QString>
#include <QStringList>
#include <QTimer>
#include <QThreadPool>
#include <QtConcurrentRun>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtypes.h>
#include <QtGui/qguiapplication_platform.h>
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <exception>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string_view>
#include <sys/poll.h>
#include <unistd.h>
#include <thread>
#include <utility>
#include <wayland-client-core.h>

namespace {

using namespace telar::gui;
using namespace telar::gui::qt;

enum class Argument : std::uint8_t { program, image, ready, output, mode, count };
enum class Phase : std::uint8_t { initial, removed_manager, restored_manager_clear, republished_after_manager, republished_live_seat, removed_seat, restored_clear, external_invalid, republished_on_retired_seat, done };

class InputWindow final : public QQuickWindow {
public:
  [[nodiscard]] bool receivedInput() const noexcept { return received_input_; }

protected:
  void keyPressEvent(QKeyEvent *event) override {
    received_input_ = received_input_ || event->key() == Qt::Key_F24;
    event->accept();
  }

private:
  bool received_input_ = false;
};

void settle() {
  const auto *const native = qGuiApp->nativeInterface<QNativeInterface::QWaylandApplication>();
  if (native == nullptr) {
    throw std::runtime_error{"MissingWaylandDisplay"};
  }

  constexpr unsigned rounds = 3;
  for (unsigned round = 0; round < rounds; ++round) {
    if (wl_display_roundtrip(native->display()) < 0) {
      throw std::runtime_error{"OwnedDisplayRoundtripFailed"};
    }

    QCoreApplication::processEvents();
  }
}

void command(std::string_view value) {
  if (::write(STDIN_FILENO, value.data(), value.size()) != static_cast<ssize_t>(value.size())) {
    throw std::runtime_error{"OwnedControlWriteFailed"};
  }

  pollfd incoming{.fd = STDIN_FILENO, .events = POLLIN, .revents = 0};
  constexpr int deadline_ms = 5000;
  char acknowledgment = 0;
  if (::poll(&incoming, 1, deadline_ms) != 1 || ::read(STDIN_FILENO, &acknowledgment, 1) != 1 || acknowledgment != 'K') {
    throw std::runtime_error{"OwnedControlReadFailed"};
  }

  settle();
}

class OwnedProbe final : public QObject {
public:
  OwnedProbe(QStringList arguments, QByteArray image)
      : arguments_(std::move(arguments)),
        image_(std::move(image)),
        worker_(memory_) {
    connect(&worker_, &ClipboardImages::ready, this, [this] { complete(); });
    connect(&ticker_, &QTimer::timeout, this, [this] { tick(); });
  }

  int run() {
    heartbeat_clock_.start();
    if (!protocol()) {
      window_.setTitle(QStringLiteral("Owned self clipboard receiver"));
      constexpr int width = 500;
      constexpr int height = 400;
      window_.resize(width, height);
      window_.show();
    }

    constexpr std::chrono::milliseconds poll{10};
    ticker_.start(poll);
    constexpr std::chrono::seconds deadline{15};
    QTimer::singleShot(deadline, this, [this] { write(false); });

    return QCoreApplication::exec();
  }

private:
  bool protocol() const { return arguments_.at(static_cast<int>(Argument::mode)).startsWith(QStringLiteral("protocol")); }

  void publish() const {
    auto mime = std::make_unique<QMimeData>();
    mime->setData(QStringLiteral("image/png"), image_);
    QGuiApplication::clipboard()->setMimeData(mime.release());
    settle();
  }

  void tick() {
    const auto now = heartbeat_clock_.nsecsElapsed();
    maximum_gap_ns_ = std::max(maximum_gap_ns_, now - last_heartbeat_ns_);
    last_heartbeat_ns_ = now;
    ++heartbeats_;
    if (started_) {
      return;
    }

    if (!protocol()) {
      if (window_.isExposed() && !mapped_) {
        QFile ready{arguments_.at(static_cast<int>(Argument::ready))};
        if (!ready.open(QIODevice::WriteOnly)) {
          throw std::runtime_error{"OwnedReadyWriteFailed"};
        }

        mapped_ = true;
      }

      if (!window_.isActive() || !window_.receivedInput()) {
        return;
      }
    }

    started_ = true;
    publish();
    capture();
  }

  ClipboardImages &activeWorker() { return replacement_ ? *replacement_ : worker_; }

  void replaceWorker() {
    replacement_.reset();
    replacement_.emplace(memory_);
    connect(&*replacement_, &ClipboardImages::ready, this, [this] { complete(); });
    settle();
  }

  void capture() {
    if (arguments_.at(static_cast<int>(Argument::mode)).endsWith(QStringLiteral("-queued")) && expectedOutcome() == QStringLiteral("ok")) {
      QThreadPool::globalInstance()->setMaxThreadCount(1);
      blocker_ = QtConcurrent::run([] {
        constexpr std::chrono::milliseconds queued_delay{1500};
        std::this_thread::sleep_for(queued_delay);
      });
    }

    elapsed_.start();
    activeWorker().capture({.source = {.machine = {.slot = 0, .generation = 0}, .generation = 1}, .runtime_generation = 1, .attachment_generation = 1, .request = {.capture = {.id = 1, .target = {.pane_id = 1, .pane_generation = 1}}}});
    snapshot_us_ = std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::nanoseconds{elapsed_.nsecsElapsed()}).count();
  }

  void complete() {
    result_ = activeWorker().takeResult();
    QTimer::singleShot(std::chrono::milliseconds::zero(), this, [this] { advance(); });
  }

  QString expectedOutcome() const {
    if (phase_ == Phase::initial || phase_ == Phase::republished_after_manager || phase_ == Phase::republished_live_seat) {
      return QStringLiteral("ok");
    }

    if (phase_ == Phase::external_invalid || phase_ == Phase::republished_on_retired_seat) {
      return QStringLiteral("InvalidClipboardImage");
    }

    return QStringLiteral("NoImageOnClipboard");
  }

  QString outcome() const {
    if (!result_) {
      return QStringLiteral("MissingCompletion");
    }

    if (result_->capture && result_->preview) {
      return QStringLiteral("ok");
    }

    return result_->error;
  }

  void advance() {
    const auto expected = expectedOutcome();
    const auto actual = outcome();
    constexpr qint64 maximum_snapshot_us = 500000;
    bool passed = actual == expected && snapshot_us_ < maximum_snapshot_us;
    QJsonObject row{{QStringLiteral("phase"), static_cast<int>(phase_)}, {QStringLiteral("actual"), actual}, {QStringLiteral("expected"), expected}, {QStringLiteral("snapshot_us"), snapshot_us_}, {QStringLiteral("elapsed_ms"), elapsed_.elapsed()}, {QStringLiteral("qt_owns_clipboard"), QGuiApplication::clipboard()->ownsClipboard()}};
    if (result_ && result_->capture) {
      const QByteArrayView png{result_->capture->png.unsignedBytes()};
      row.insert(QStringLiteral("png_sha256"), QString::fromLatin1(QCryptographicHash::hash(png, QCryptographicHash::Sha256).toHex()));
      passed = passed && png == QByteArrayView{image_};
    }

    row.insert(QStringLiteral("passed"), passed);
    rows_.append(row);
    if (!passed || !protocol()) {
      write(passed);

      return;
    }

    phase_ = static_cast<Phase>(static_cast<unsigned>(phase_) + 1);
    switch (phase_) {
    case Phase::removed_seat: command("remove-seat"); break;
    case Phase::restored_clear: command("restore-seat"); command("clear"); replaceWorker(); break;
    case Phase::removed_manager: command("remove-manager"); break;
    case Phase::restored_manager_clear: command("restore-manager"); command("clear"); break;
    case Phase::republished_after_manager: publish(); break;
    case Phase::republished_live_seat: replaceWorker(); publish(); break;
    case Phase::external_invalid: command("select"); break;
    case Phase::republished_on_retired_seat: publish(); break;
    case Phase::done: write(true); return;
    case Phase::initial: throw std::runtime_error{"InvalidProbePhase"};
    }

    result_.reset();
    capture();
  }

  void write(bool passed) {
    ticker_.stop();
    maximum_gap_ns_ = std::max(maximum_gap_ns_, heartbeat_clock_.nsecsElapsed() - last_heartbeat_ns_);
    const auto maximum_gap_us = std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::nanoseconds{maximum_gap_ns_}).count();
    constexpr qint64 maximum_admitted_gap_us = 500000;
    const bool queued = arguments_.at(static_cast<int>(Argument::mode)).endsWith(QStringLiteral("-queued"));
    passed = passed && (!queued || maximum_gap_us < maximum_admitted_gap_us);
    const QJsonObject record{{QStringLiteral("passed"), passed}, {QStringLiteral("queued_worker"), queued}, {QStringLiteral("maximum_heartbeat_gap_us"), static_cast<qint64>(maximum_gap_us)}, {QStringLiteral("cases"), rows_}, {QStringLiteral("heartbeats"), static_cast<qint64>(heartbeats_)}, {QStringLiteral("scope"), protocol() ? QStringLiteral("Owned Qt clipboard protocol; no surface/window") : QStringLiteral("Owned native Wayland window; delivered F24; self-owned PNG worker capture")}};
    const auto bytes = QJsonDocument{record}.toJson(QJsonDocument::Indented);
    QFile output{arguments_.at(static_cast<int>(Argument::output))};
    const bool written = output.open(QIODevice::WriteOnly) && output.write(bytes) == bytes.size();
    QCoreApplication::exit(passed && written ? 0 : 1);
  }

  QStringList arguments_;
  QByteArray image_;
  ApplicationAllocator memory_;
  ClipboardImages worker_;
  std::optional<ClipboardImages> replacement_;
  InputWindow window_;
  QTimer ticker_;
  QElapsedTimer elapsed_;
  QElapsedTimer heartbeat_clock_;
  QFuture<void> blocker_;
  qint64 maximum_gap_ns_ = 0;
  qint64 last_heartbeat_ns_ = 0;
  std::optional<ClipboardImageResult> result_;
  QJsonArray rows_;
  Phase phase_ = Phase::initial;
  qint64 snapshot_us_ = 0;
  std::uint64_t heartbeats_ = 0;
  bool started_ = false;
  bool mapped_ = false;
};

}

int main(int argc, char **argv) try {
  const QGuiApplication application{argc, argv};
  const auto arguments = QCoreApplication::arguments();
  if (arguments.size() != static_cast<int>(Argument::count)) {
    return 1;
  }

  QFile source{arguments.at(static_cast<int>(Argument::image))};
  if (!source.open(QIODevice::ReadOnly)) {
    return 1;
  }

  OwnedProbe probe{arguments, source.readAll()};

  return probe.run();
} catch (const std::exception &) {
  return 2;
}
