#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "animation_presentation.hpp"
#include "../application/dependencies.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>
#include <algorithm>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include "../platform/window.hpp"
#include "../tests/platform/window_activation.hpp"
#include "../qt/application.hpp"
#include "../qt/bundled_fonts.hpp"
#include "../qt/list_model.hpp"
#include "../qt/modal_reveal_layout.hpp"
#include "../qt/native_rounded_rectangle.hpp"
#include "../qt/tab_strip_layout.hpp"
#include "../qt/window_animation_clock.hpp"
#include <QCommandLineParser>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QJsonObject>
#include <QQuickWindow>
#include <QScreen>
#include <QTimer>
#include <QVariantMap>
#include <iostream>
#include <memory>

#include "application/dependencies.hpp"
#include "platform/window.hpp"
#include "platform/window_activation.hpp"
#include "qt/application.hpp"
#include "qt/bundled_fonts.hpp"
#include "qt/list_model.hpp"
#include "qt/modal_reveal_layout.hpp"
#include "qt/native_rounded_rectangle.hpp"
#include "qt/tab_strip_layout.hpp"
#include "qt/window_animation_clock.hpp"


import telar.gui.core.metrics;
import telar.gui.platform.profile_file;

namespace {

using namespace telar::gui;
using namespace telar::gui::qt;

constexpr int window_width = 800;
constexpr int window_height = 240;
constexpr int cycle_ms = 400;
constexpr int cycle_count = 12;
constexpr int warmup_cycles = 2;
constexpr int settle_ms = 150;
constexpr int warmup_ms = 1000;
constexpr qreal travel = 400;

QList<QVariantMap> tabRows(bool reversed) {
  QList<QVariantMap> rows;
  constexpr int tabs = 4;
  for (int index = 0; index < tabs; ++index) {
    const auto id = reversed ? tabs - index : index + 1;
    rows.append({
        {QStringLiteral("key"), QString::number(id)},
        {QStringLiteral("label"), QStringLiteral("Terminal %1").arg(id)},
        {QStringLiteral("selected"), id == 1},
    });
  }
  return rows;
}

}

int main(int argc, char **argv) {
  QGuiApplication application{argc, argv};
  platform::configureGraphics();
  bundledFonts();
  QCommandLineParser parser;
  parser.addHelpOption();
  parser.addOption({QStringLiteral("mode"), QStringLiteral("modal, tabs or continuous"), QStringLiteral("mode"), QStringLiteral("modal")});
  parser.addOption({QStringLiteral("screen"), QStringLiteral("Qt screen index"), QStringLiteral("index"), QStringLiteral("0")});
  parser.addOption({QStringLiteral("config"), QStringLiteral("Optional GUI configuration, including max_fps"), QStringLiteral("path")});
  parser.addOption({QStringLiteral("pacer"), QStringLiteral("Application pacing: on or off"), QStringLiteral("mode"), QStringLiteral("on")});
  parser.process(application);
  const auto mode = parser.value(QStringLiteral("mode"));
  const auto screen_index = parser.value(QStringLiteral("screen")).toInt();
  if (!QStringList{QStringLiteral("modal"), QStringLiteral("tabs"), QStringLiteral("continuous")}.contains(mode) || screen_index < 0 || screen_index >= QGuiApplication::screens().size()) {
    return 2;
  }

  probe::observeAnimationPresentation();
  ApplicationAllocator memory;
  std::unique_ptr<Application> client;
  QQuickWindow window;
  window.resize(window_width, window_height);
  auto *screen = QGuiApplication::screens()[screen_index];
  window.setScreen(screen);
  window.setPosition(screen->availableGeometry().center() - QPoint{window_width / 2, window_height / 2});
  test::configureComponentWindow(window);
  window.setFlag(Qt::WindowStaysOnTopHint, true);
  if (parser.value(QStringLiteral("pacer")) == QStringLiteral("on")) {
    client = std::make_unique<Application>(memory);
    if (parser.isSet(QStringLiteral("config"))) {
      client->loadConfiguration(parser.value(QStringLiteral("config")), {}, {});
    }
    client->setWindow(window);
  }

  ModalRevealLayout modal{window.contentItem()};
  modal.setSize(QSizeF{window_width, window_height});
  ListModel tabs;
  tabs.reconcile(tabRows(false));
  TabStripLayout strip{window.contentItem()};
  strip.setSize(QSizeF{window_width, 42});
  strip.setModel(&tabs);
  strip.setContext(1, telar::WorkspaceLocation{.id = 1});
  strip.setVisible(mode == QStringLiteral("tabs"));
  std::array<std::unique_ptr<NativeRoundedRectangle>, 4> boxes;
  for (auto &box : boxes) {
    box = std::make_unique<NativeRoundedRectangle>(window.contentItem());
    box->setSize(QSizeF{60, 30});
    box->setColor(QColor{QStringLiteral("#aa87f5")});
    box->setY(80);
  }
  if (mode != QStringLiteral("tabs")) {
    for (std::size_t index = 1; index < boxes.size(); ++index) {
      boxes[index]->setVisible(false);
    }
  }
  QObject::connect(&modal, &ModalRevealLayout::frameChanged, &window, [&] {
    if (mode == QStringLiteral("modal")) {
      boxes[0]->setX(modal.reveal() * travel);
    }
  });
  QObject::connect(&strip, &TabStripLayout::layoutChanged, &window, [&] {
    if (mode != QStringLiteral("tabs")) {
      return;
    }
    for (int row = 0; row < strip.items()->rowCount(); ++row) {
      const auto record = strip.items()->data(strip.items()->index(row, 0), ListModel::record_role).toMap();
      const auto id = record.value(QStringLiteral("key")).toString().toInt();
      boxes.at(static_cast<std::size_t>(id - 1))->setX(record.value(QStringLiteral("bounds")).toRectF().x());
    }
  });

  std::uint64_t cycle = 0;
  struct Prepared {
    std::uint64_t cycle = 0;
    double value = 0;
  } prepared;
  QObject::connect(&window, &QQuickWindow::afterSynchronizing, &window, [&] {
    prepared = {.cycle = cycle > warmup_cycles ? cycle - warmup_cycles : 0, .value = boxes[0]->x()};
  }, Qt::DirectConnection);
  QObject::connect(&window, &QQuickWindow::afterRendering, &window, [&] {
    probe::recordAnimationPresentation(prepared.cycle, prepared.value);
  }, Qt::DirectConnection);

  QTimer cycles;
  cycles.setTimerType(Qt::PreciseTimer);
  cycles.setInterval(cycle_ms);
  QObject::connect(&cycles, &QTimer::timeout, &window, [&] {
    ++cycle;
    if (cycle > cycle_count + warmup_cycles) {
      cycles.stop();
      QTimer::singleShot(settle_ms, &application, &QGuiApplication::quit);
      return;
    }
    if (mode == QStringLiteral("modal")) {
      modal.setGeneration(QString::number(cycle));
      modal.setActive(true);
    } else if (mode == QStringLiteral("tabs")) {
      tabs.reconcile(tabRows(cycle % 2 != 0));
    }
  });
  QTimer continuous;
  continuous.setTimerType(Qt::PreciseTimer);
  continuous.setInterval(1);
  QObject::connect(&continuous, &QTimer::timeout, &window, [&] {
    constexpr std::uint64_t period_ns = 1'000'000'000;
    const auto now = platform::AwakeClock::nowNanoseconds();
    boxes[0]->setX(travel * static_cast<double>(now % period_ns) / period_ns);
  });
  QTimer::singleShot(warmup_ms, &window, [&] {
    cycles.start();
    if (mode == QStringLiteral("continuous")) {
      continuous.start();
    }
  });
  window.show();
  test::activateWindow(window);
  QTimer::singleShot(0, &window, [&] {
    window.setPosition(screen->availableGeometry().center() - QPoint{window_width / 2, window_height / 2});
  });
  const auto status = application.exec();
  QJsonObject report{
      {QStringLiteral("requested_screen"), screen->name()},
      {QStringLiteral("actual_qt_screen"), window.screen()->name()},
      {QStringLiteral("window_x"), window.x()},
      {QStringLiteral("window_y"), window.y()},
      {QStringLiteral("width"), window.width()},
      {QStringLiteral("height"), window.height()},
      {QStringLiteral("configured_max_fps"), client == nullptr ? 0 : client->configuration().max_fps},
      {QStringLiteral("mode"), mode},
      {QStringLiteral("application_pacer"), client != nullptr},
      {QStringLiteral("qt_refresh_rate"), window.screen()->refreshRate()},
      {QStringLiteral("animation_interval_ns"), static_cast<qint64>(WindowAnimationClock::forWindow(window).frameInterval())},
      {QStringLiteral("display"), probe::animationDisplay(window)},
      {QStringLiteral("presentations"), probe::animationPresentations()},
  };
  std::cout << QJsonDocument{report}.toJson(QJsonDocument::Compact).constData() << '\n';
  return status;
}
