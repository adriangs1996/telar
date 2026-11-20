#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "animation_presentation.hpp"
#include "foundation/core/application_memory.hpp"
#include "platform/window.hpp"
#include "platform/window_activation.hpp"
#include "telar_base/ds/values.hpp"
#include "ui/app/application_controller.hpp"
#include "ui/app/chrome/tabs/tab_strip_layout.hpp"
#include "ui/design/controls/modal_reveal_layout.hpp"
#include "ui/design/controls/native_rounded_rectangle.hpp"
#include "ui/foundation/fonts/bundled_fonts.hpp"
#include "ui/foundation/models/list_model.hpp"
#include "ui/foundation/scene/window_animation_clock.hpp"
#include <QCommandLineParser>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QJsonObject>
#include <QQuickWindow>
#include <QScreen>
#include <QTimer>
#include <QVariantMap>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <exception>
#include <iostream>
#include <memory>
#include <optional>
#include <utility>

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

  using Boxes = telar::ds::Array<std::unique_ptr<NativeRoundedRectangle>, 4>;

  struct Prepared {
    std::uint64_t cycle = 0;
    double value = 0;
  };

  // Declared in construction order, so teardown stops the timers before the items they move.
  struct Animation {
    QString mode;
    ModalRevealLayout modal;
    ListModel tabs;
    TabStripLayout strip;
    Boxes boxes;
    std::uint64_t cycle = 0;
    Prepared prepared;
    QTimer cycles;
    QTimer continuous;

    Animation(QString mode, QQuickItem* parent)
        : mode{std::move(mode)},
          modal{parent},
          strip{parent} {}
  };

  void addOptions(QCommandLineParser& parser) {
    parser.addHelpOption();
    parser.addOption({QStringLiteral("mode"), QStringLiteral("modal, tabs or continuous"), QStringLiteral("mode"), QStringLiteral("modal")});
    parser.addOption({QStringLiteral("screen"), QStringLiteral("Qt screen index"), QStringLiteral("index"), QStringLiteral("0")});
    parser.addOption({QStringLiteral("config"), QStringLiteral("Optional GUI configuration, including max_fps"), QStringLiteral("path")});
    parser.addOption({QStringLiteral("pacer"), QStringLiteral("Application pacing: on or off"), QStringLiteral("mode"), QStringLiteral("on")});
  }

  void centerWindow(QQuickWindow& window, const QScreen& screen) {
    window.setPosition(screen.availableGeometry().center() - QPoint{window_width / 2, window_height / 2});
  }

  tbc::val_a<std::unique_ptr<ApplicationController>> pacedClient(tbc::mut_a<ApplicationAllocator> memory, const QCommandLineParser& parser, QQuickWindow& window) {
    auto client = std::make_unique<ApplicationController>(memory);

    if (parser.isSet(QStringLiteral("config"))) {
      client->loadConfiguration(parser.value(QStringLiteral("config")), {}, {});
    }

    client->setWindow(window);
    return client;
  }

  void layOut(Animation& animation, QQuickItem* parent) {
    constexpr qreal strip_height = 42;
    constexpr QSizeF box_size{60, 30};
    constexpr qreal box_y = 80;

    animation.modal.setSize(QSizeF{window_width, window_height});
    animation.tabs.reconcile(tabRows(false));
    animation.strip.setSize(QSizeF{window_width, strip_height});
    animation.strip.setModel(&animation.tabs);
    animation.strip.setContext(1, telar::WorkspaceLocation{.id = 1});
    animation.strip.setVisible(animation.mode == QStringLiteral("tabs"));
    for (auto& box : animation.boxes.viewMut()) {
      box = std::make_unique<NativeRoundedRectangle>(parent);
      box->setSize(box_size);
      box->setColor(QColor{QStringLiteral("#aa87f5")});
      box->setY(box_y);
    }

    if (animation.mode != QStringLiteral("tabs")) {
      for (std::size_t index = 1; index < animation.boxes.size(); ++index) {
        animation.boxes.atMut(index)->setVisible(false);
      }
    }
  }

  void followLayouts(Animation& animation, const QQuickWindow& window) {
    QObject::connect(&animation.modal, &ModalRevealLayout::frameChanged, &window, [&animation] {
      if (animation.mode == QStringLiteral("modal")) {
        animation.boxes.atMut(0)->setX(animation.modal.reveal() * travel);
      }
    });

    QObject::connect(&animation.strip, &TabStripLayout::layoutChanged, &window, [&animation] {
      if (animation.mode != QStringLiteral("tabs")) {
        return;
      }

      for (int row = 0; row < animation.strip.items()->rowCount(); ++row) {
        const auto record = animation.strip.items()->data(animation.strip.items()->index(row, 0), ListModel::record_role).toMap();
        const auto id = record.value(QStringLiteral("key")).toString().toInt();

        animation.boxes.atCheckedMut(static_cast<std::size_t>(id - 1))->setX(record.value(QStringLiteral("bounds")).toRectF().x());
      }
    });
  }

  void recordPresentations(Animation& animation, const QQuickWindow& window) {
    QObject::connect(&window, &QQuickWindow::afterSynchronizing, &window, [&animation] {
      animation.prepared = {.cycle = animation.cycle > warmup_cycles ? animation.cycle - warmup_cycles : 0, .value = animation.boxes[0]->x()};
    },
        Qt::DirectConnection);

    QObject::connect(&window, &QQuickWindow::afterRendering, &window, [&animation] {
      probe::recordAnimationPresentation(animation.prepared.cycle, animation.prepared.value);
    },
        Qt::DirectConnection);
  }

  void driveCycles(Animation& animation, const QQuickWindow& window, const QGuiApplication& application) {
    animation.cycles.setTimerType(Qt::PreciseTimer);
    animation.cycles.setInterval(cycle_ms);
    QObject::connect(&animation.cycles, &QTimer::timeout, &window, [&animation, &application] {
      ++animation.cycle;
      if (animation.cycle > cycle_count + warmup_cycles) {
        animation.cycles.stop();
        QTimer::singleShot(settle_ms, &application, &QGuiApplication::quit);
        return;
      }

      if (animation.mode == QStringLiteral("modal")) {
        animation.modal.setGeneration(QString::number(animation.cycle));
        animation.modal.setActive(true);
      } else if (animation.mode == QStringLiteral("tabs")) {
        animation.tabs.reconcile(tabRows(animation.cycle % 2 != 0));
      }
    });

    animation.continuous.setTimerType(Qt::PreciseTimer);
    animation.continuous.setInterval(1);
    QObject::connect(&animation.continuous, &QTimer::timeout, &window, [&animation] {
      constexpr std::uint64_t period_ns = 1'000'000'000;
      const auto now = system::AwakeClock::nowNanoseconds();

      animation.boxes.atMut(0)->setX(travel * static_cast<double>(now % period_ns) / period_ns);
    });

    QTimer::singleShot(warmup_ms, &window, [&animation] {
      animation.cycles.start();
      if (animation.mode == QStringLiteral("continuous")) {
        animation.continuous.start();
      }
    });
  }

  QJsonObject report(QQuickWindow& window, const QScreen& screen, const ApplicationController* client, const QString& mode) {
    return {
        {QStringLiteral("requested_screen"), screen.name()},
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
  }

}

int main(int argc, char** argv) try {
  const QGuiApplication application{argc, argv};

  platform::configureGraphics();
  bundledFonts();
  QCommandLineParser parser;

  addOptions(parser);
  parser.process(application);
  const auto mode = parser.value(QStringLiteral("mode"));
  const auto screen_index = parser.value(QStringLiteral("screen")).toInt();
  if (!QStringList{QStringLiteral("modal"), QStringLiteral("tabs"), QStringLiteral("continuous")}.contains(mode) || screen_index < 0 || screen_index >= QGuiApplication::screens().size()) {
    return 2;
  }

  probe::observeAnimationPresentation();
  ApplicationMemory application_memory;
  ApplicationAllocator& memory = application_memory.memory();
  std::unique_ptr<ApplicationController> client;
  QQuickWindow window;

  window.resize(window_width, window_height);
  auto* screen = QGuiApplication::screens()[screen_index];

  window.setScreen(screen);
  centerWindow(window, *screen);
  test::configureComponentWindow(window);
  window.setFlag(Qt::WindowStaysOnTopHint, true);
  if (parser.value(QStringLiteral("pacer")) == QStringLiteral("on")) {
    client = pacedClient(memory, parser, window);
  }

  Animation animation{mode, window.contentItem()};

  layOut(animation, window.contentItem());
  followLayouts(animation, window);
  recordPresentations(animation, window);
  driveCycles(animation, window, application);
  window.show();
  test::activateWindow(window);
  QTimer::singleShot(0, &window, [&] {
    centerWindow(window, *screen);
  });

  const auto status = QGuiApplication::exec();

  std::cout << QJsonDocument{report(window, *screen, client.get(), mode)}.toJson(QJsonDocument::Compact).constData() << '\n';
  return status;
} catch (const std::exception& error) {
  std::cerr << error.what() << '\n';

  return EXIT_FAILURE;
}
