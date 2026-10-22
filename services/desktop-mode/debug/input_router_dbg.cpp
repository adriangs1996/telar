// Measures moving the keyboard focus between pane windows in two ways:
//
//   activate  Every pane is a window that becomes key when it is focused: raise, requestActivate
//             and forceActiveFocus.
//   router    The workbench's KeyboardRouter: panes never become key, and one invisible input
//             window keeps the key window and routes the keyboard and the input method to the
//             focused pane.
//
// Every pane has the same input item in both modes; only how the keyboard reaches it changes.
// Interactively, physical ctrl+h/j/k/l and clicks move the focus, typing goes to the focused
// pane, and every change of Qt's focus window is printed, so focus on the wrong pane shows up.
// --bench N moves the focus N times once the application is active and prints how long each move
// takes: "call" is the synchronous move, "settled" lasts until the event loop is idle again with
// the focused pane holding the keyboard.

#include "ui/workbench/keyboard_router.hpp"
#include <QCommandLineParser>
#include <QGuiApplication>
#include <QInputMethod>
#include <QInputMethodEvent>
#include <QKeyEvent>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include <QScreen>
#include <QTimer>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <memory>
#include <optional>
#include <stdexcept>
#include <vector>

namespace {
  using Clock = std::chrono::steady_clock;
  using Milliseconds = std::chrono::duration<double, std::milli>;

  enum class Mode { activate, router };

  constexpr int maximum_panes = 16;
  constexpr qsizetype maximum_buffer = 4096;
  constexpr int screen_margin = 40;
  constexpr int pane_gap = 8;
  constexpr auto ready_poll = std::chrono::milliseconds{100};
  constexpr auto ready_deadline = std::chrono::seconds{30};
  constexpr auto settle_deadline = std::chrono::seconds{1};

  constexpr auto pane_source = R"qml(
import QtQuick

Rectangle {
    id: root

    property int index: 0
    property bool focused: false
    property string buffer: ""
    property string preedit: ""
    readonly property Item edit: edit
    readonly property rect cursor: {
        edit.text;
        return edit.positionToRectangle(root.buffer.length);
    }

    color: "#1d1f21"
    border.width: 2
    border.color: focused ? "#5fafff" : "#3a3a3a"

    Text {
        id: title
        x: 12
        y: 8
        color: "#8a8a8a"
        font.pixelSize: 12
        text: "pane " + root.index + (root.focused ? " · focused" : "")
    }

    TextEdit {
        id: edit
        anchors.fill: parent
        anchors.topMargin: title.y + title.height + 8
        anchors.leftMargin: 12
        anchors.rightMargin: 12
        anchors.bottomMargin: 12
        readOnly: true
        activeFocusOnPress: false
        color: "#e0e0e0"
        font.family: "Menlo"
        font.pixelSize: 14
        wrapMode: TextEdit.WrapAnywhere
        text: root.buffer
    }

    Text {
        id: composition
        x: edit.x + root.cursor.x
        y: edit.y + root.cursor.y
        color: "#ffd75f"
        font: edit.font
        text: root.preedit

        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 1
            color: parent.color
        }
    }

    Rectangle {
        visible: root.focused && root.preedit.length === 0
        x: edit.x + root.cursor.x
        y: edit.y + root.cursor.y
        width: 2
        height: root.cursor.height
        color: "#5fafff"
    }
}
)qml";

  double percentile(const std::vector<double> &sorted, int percent) {
    const auto index = std::min(sorted.size() - 1, sorted.size() * percent / 100);
    return sorted[index];
  }

  void report(const char *label, std::vector<double> values) {
    if (values.empty()) {
      std::printf("  %-8s no samples\n", label);
      return;
    }

    std::sort(values.begin(), values.end());
    double total = 0;
    for (const auto value : values) {
      total += value;
    }

    std::printf("  %-8s p50 %7.3f ms  p95 %7.3f ms  max %7.3f ms  total %8.1f ms\n",
                label,
                percentile(values, 50),
                percentile(values, 95),
                values.back(),
                total);
  }

  class Router;

  // Receives the keyboard and the input method of one pane, like a terminal item.
  class PaneInput final : public QQuickItem {
  public:
    PaneInput(Router &router, int index, QQuickItem *parent);

  protected:
    void keyPressEvent(QKeyEvent *event) override;
    void inputMethodEvent(QInputMethodEvent *event) override;
    QVariant inputMethodQuery(Qt::InputMethodQuery query) const override;

  private:
    Router &router_;
    int index_;
  };

  class Router final : public QObject {
  public:
    Router(QQmlEngine &engine, Mode mode, int count)
        : mode_(mode) {
      QQmlComponent component(&engine);
      component.setData(pane_source, QUrl());
      if (component.isError()) {
        throw std::runtime_error(component.errorString().toStdString());
      }

      if (mode_ == Mode::router) {
        keyboard_.emplace();
      }

      panes_.resize(count);
      for (int index = 0; index < count; ++index) {
        auto &pane = panes_[index];
        pane.window = std::make_unique<QQuickWindow>();
        pane.window->setColor(QColor(0x1d, 0x1f, 0x21));
        pane.window->setTitle(QStringLiteral("pane %1").arg(index));
        pane.window->setFlags(Qt::Window | Qt::FramelessWindowHint);
        pane.root = qobject_cast<QQuickItem *>(component.create());
        if (!pane.root) {
          throw std::runtime_error(component.errorString().toStdString());
        }

        pane.root->setParent(pane.window->contentItem());
        pane.root->setParentItem(pane.window->contentItem());
        pane.root->setProperty("index", index);
        pane.edit = qvariant_cast<QQuickItem *>(pane.root->property("edit"));
        pane.input = new PaneInput(*this, index, pane.window->contentItem());
        if (keyboard_) {
          keyboard_->adopt(*pane.window, [this, index] {
            clicked(index);
          });
        } else {
          pane.window->setProperty("_q_showWithoutActivating", true);
          pane.window->installEventFilter(this);
        }
      }

      QObject::connect(qGuiApp, &QGuiApplication::focusWindowChanged, this, [this](QWindow *window) {
        focusWindowChanged(window);
      });

      QObject::connect(qGuiApp,
                       &QGuiApplication::applicationStateChanged,
                       this,
                       [](Qt::ApplicationState state) {
                         std::printf("application %s\n",
                                     state == Qt::ApplicationActive ? "active" : "inactive");
                         std::fflush(stdout);
                       });
    }

    ~Router() override {
      stopReporting();
    }

    // Closing the windows moves the focus between them; that is not worth reporting.
    void stopReporting() {
      QObject::disconnect(qGuiApp, nullptr, this, nullptr);
    }

    void show() {
      place();
      for (auto &pane : panes_) {
        render(pane);
        pane.window->show();
      }

      deliver(panes_[focused_]);
    }

    int count() const {
      return static_cast<int>(panes_.size());
    }

    int focused() const {
      return focused_;
    }

    // Whether the focused pane receives the keyboard, down to its input item.
    bool settled() const {
      const auto &pane = panes_[focused_];
      const bool holds = keyboard_ ? keyboard_->holds(*pane.window)
                                   : QGuiApplication::focusWindow() == pane.window.get();
      return holds && pane.input->hasActiveFocus();
    }

    void setQuiet(bool quiet) {
      quiet_ = quiet;
      focus_changes_ = 0;
      unexpected_ = 0;
    }

    int focusChanges() const {
      return focus_changes_;
    }

    int unexpected() const {
      return unexpected_;
    }

    Milliseconds focus(int index) {
      const auto start = Clock::now();
      if (index == focused_) {
        return {};
      }

      auto &previous = panes_[focused_];
      focused_ = index;
      render(previous);
      render(panes_[focused_]);
      deliver(panes_[focused_]);
      return Clock::now() - start;
    }

    void moveBy(int columns, int rows) {
      const int column = focused_ % columns_ + columns;
      const int row = focused_ / columns_ + rows;
      const int target = row * columns_ + column;
      if (column < 0 || column >= columns_ || row < 0 || target >= count()) {
        return;
      }

      const auto elapsed = focus(target);
      std::printf("focus pane %d in %.3f ms\n", target, elapsed.count());
      std::fflush(stdout);
    }

    void type(int index, const QKeyEvent &event) {
      auto &pane = panes_[index];
      if (event.key() == Qt::Key_Backspace) {
        pane.buffer.chop(1);
      } else if (event.key() == Qt::Key_Return || event.key() == Qt::Key_Enter) {
        pane.buffer += QLatin1Char('\n');
      } else if (!event.text().isEmpty() && event.text().front().isPrint()) {
        pane.buffer += event.text();
      } else {
        return;
      }

      render(pane);
    }

    void compose(int index, const QInputMethodEvent &event) {
      auto &pane = panes_[index];
      pane.buffer += event.commitString();
      pane.preedit = event.preeditString();
      render(pane);
    }

    // The pane's cursor in its window's coordinates.
    QRectF cursor(int index) const {
      const auto &pane = panes_[index];
      const auto rect = pane.root->property("cursor").toRectF();
      return pane.edit->mapRectToScene(rect);
    }

  protected:
    // Activate mode only: the router reports presses itself.
    bool eventFilter(QObject *watched, QEvent *event) override {
      if (event->type() != QEvent::MouseButtonPress) {
        return false;
      }

      for (int index = 0; index < count(); ++index) {
        if (panes_[index].window.get() == watched) {
          clicked(index);
          break;
        }
      }

      return false;
    }

  private:
    struct Pane {
      std::unique_ptr<QQuickWindow> window;
      // These belong to the window's content item.
      QQuickItem *root = nullptr;
      QQuickItem *edit = nullptr;
      PaneInput *input = nullptr;
      QString buffer;
      QString preedit;
    };

    void place() {
      const auto area = QGuiApplication::primaryScreen()->availableGeometry().adjusted(
          screen_margin, screen_margin, -screen_margin, -screen_margin);
      columns_ = static_cast<int>(std::ceil(std::sqrt(count())));
      const int rows = (count() + columns_ - 1) / columns_;
      const int width = (area.width() - pane_gap * (columns_ - 1)) / columns_;
      const int height = (area.height() - pane_gap * (rows - 1)) / rows;

      for (int index = 0; index < count(); ++index) {
        auto &pane = panes_[index];
        const int x = area.x() + index % columns_ * (width + pane_gap);
        const int y = area.y() + index / columns_ * (height + pane_gap);
        pane.window->setGeometry(x, y, width, height);
        pane.root->setSize(QSizeF(width, height));
      }
    }

    void clicked(int index) {
      const auto elapsed = focus(index);
      std::printf("click pane %d, focused in %.3f ms\n", index, elapsed.count());
      std::fflush(stdout);
    }

    void deliver(Pane &pane) {
      if (keyboard_) {
        keyboard_->route(*pane.window);
        return;
      }

      pane.window->raise();
      pane.window->requestActivate();
      pane.input->forceActiveFocus();
    }

    void render(Pane &pane) {
      if (pane.buffer.size() > maximum_buffer) {
        pane.buffer.remove(0, pane.buffer.size() - maximum_buffer);
      }

      pane.root->setProperty("focused", &pane == &panes_[focused_]);
      pane.root->setProperty("buffer", pane.buffer);
      pane.root->setProperty("preedit", pane.preedit);
      if (pane.input->hasActiveFocus()) {
        QGuiApplication::inputMethod()->update(Qt::ImCursorRectangle);
      }
    }

    bool isPane(QWindow *window) const {
      return std::any_of(panes_.begin(), panes_.end(), [window](const Pane &pane) {
        return pane.window.get() == window;
      });
    }

    // Qt's focus window: the key window in activate mode, the routed pane in router mode. Either
    // way, only the focused pane may have it.
    void focusWindowChanged(QWindow *window) {
      ++focus_changes_;
      const bool expected = !window || !isPane(window) || window == panes_[focused_].window.get();
      if (!expected) {
        ++unexpected_;
      }

      if (!quiet_ || !expected) {
        std::printf("focus window: %s%s\n",
                    window ? qPrintable(window->title()) : "none",
                    expected ? "" : "  (unexpected)");
        std::fflush(stdout);
      }
    }

    Mode mode_;
    // Declared before the panes, so it outlives their windows.
    std::optional<workbench::KeyboardRouter> keyboard_;
    std::vector<Pane> panes_;
    int focused_ = 0;
    int columns_ = 1;
    bool quiet_ = false;
    int focus_changes_ = 0;
    int unexpected_ = 0;
  };

  PaneInput::PaneInput(Router &router, int index, QQuickItem *parent)
      : QQuickItem(parent),
        router_(router),
        index_(index) {
    setFlag(ItemAcceptsInputMethod);
    setFocus(true);
  }

  void PaneInput::keyPressEvent(QKeyEvent *event) {
    // Physical ctrl is Qt::MetaModifier on macOS.
    if (event->modifiers() == Qt::MetaModifier) {
      switch (event->key()) {
      case Qt::Key_H:
        router_.moveBy(-1, 0);
        return event->accept();
      case Qt::Key_L:
        router_.moveBy(1, 0);
        return event->accept();
      case Qt::Key_K:
        router_.moveBy(0, -1);
        return event->accept();
      case Qt::Key_J:
        router_.moveBy(0, 1);
        return event->accept();
      default:
        break;
      }
    }

    router_.type(index_, *event);
    event->accept();
  }

  void PaneInput::inputMethodEvent(QInputMethodEvent *event) {
    router_.compose(index_, *event);
    event->accept();
  }

  QVariant PaneInput::inputMethodQuery(Qt::InputMethodQuery query) const {
    switch (query) {
    case Qt::ImEnabled:
      return true;
    case Qt::ImCursorRectangle:
      return mapRectFromScene(router_.cursor(index_));
    case Qt::ImHints:
      return static_cast<int>(Qt::ImhNoPredictiveText | Qt::ImhNoAutoUppercase);
    default:
      return QQuickItem::inputMethodQuery(query);
    }
  }

  // Moves the focus to the next pane, one move at a time: each waits until the previous one has
  // settled and the interval has passed.
  class Bench {
  public:
    Bench(Router &router, int moves, std::chrono::milliseconds interval, bool quit)
        : router_(router),
          moves_(moves),
          interval_(interval),
          quit_(quit) {}

    void start() {
      waitReady(Clock::now() + ready_deadline);
    }

  private:
    void waitReady(Clock::time_point deadline) {
      if (qGuiApp->applicationState() == Qt::ApplicationActive && router_.settled()) {
        router_.setQuiet(true);
        step();
        return;
      }

      if (Clock::now() > deadline) {
        std::printf("bench: the application never became active with the expected key window\n");
        std::fflush(stdout);
        return;
      }

      if (!hinted_) {
        hinted_ = true;
        std::printf("bench: waiting for the application to be active; click a pane if it is not\n");
        std::fflush(stdout);
      }

      QTimer::singleShot(ready_poll, &router_, [this, deadline] {
        waitReady(deadline);
      });
    }

    void step() {
      if (static_cast<int>(calls_.size()) == moves_) {
        finish();
        return;
      }

      const auto start = Clock::now();
      calls_.push_back(router_.focus((router_.focused() + 1) % router_.count()).count());
      QTimer::singleShot(0, &router_, [this, start] {
        settle(start);
      });
    }

    void settle(Clock::time_point start) {
      const auto elapsed = Clock::now() - start;
      if (!router_.settled() && elapsed < settle_deadline) {
        QTimer::singleShot(0, &router_, [this, start] {
          settle(start);
        });
        return;
      }

      if (router_.settled()) {
        settles_.push_back(Milliseconds(elapsed).count());
      } else {
        ++unsettled_;
      }

      QTimer::singleShot(interval_, &router_, [this] {
        step();
      });
    }

    void finish() {
      std::printf("bench: %d focus moves across %d panes\n", moves_, router_.count());
      report("call", calls_);
      report("settled", settles_);
      std::printf("  focus window changes %d, unexpected %d, unsettled moves %d\n",
                  router_.focusChanges(),
                  router_.unexpected(),
                  unsettled_);
      std::fflush(stdout);
      router_.setQuiet(false);

      if (quit_) {
        router_.stopReporting();
        QCoreApplication::quit();
      }
    }

    Router &router_;
    int moves_;
    std::chrono::milliseconds interval_;
    bool quit_;
    bool hinted_ = false;
    int unsettled_ = 0;
    std::vector<double> calls_;
    std::vector<double> settles_;
  };
} // namespace

int main(int argc, char **argv) {
  QGuiApplication application(argc, argv);
  QCommandLineParser parser;
  parser.setApplicationDescription(
      "Compares activating pane windows with routing the keyboard through one input window.");
  parser.addHelpOption();
  const QCommandLineOption mode_option("mode", "activate or router (default).", "mode", "router");
  const QCommandLineOption panes_option("panes", "Pane windows, 1 to 16 (default 4).", "count", "4");
  const QCommandLineOption bench_option("bench", "Focus moves to measure (default 0).", "moves", "0");
  const QCommandLineOption interval_option(
      "interval", "Pause between measured moves (default 40).", "ms", "40");
  const QCommandLineOption quit_option("quit", "Quit once the bench has reported.");
  parser.addOptions({mode_option, panes_option, bench_option, interval_option, quit_option});
  parser.process(application);

  const auto mode_name = parser.value(mode_option);
  bool panes_valid = false, bench_valid = false, interval_valid = false;
  const int panes = parser.value(panes_option).toInt(&panes_valid);
  const int moves = parser.value(bench_option).toInt(&bench_valid);
  const int interval = parser.value(interval_option).toInt(&interval_valid);
  if ((mode_name != "activate" && mode_name != "router") || !panes_valid || panes < 1 ||
      panes > maximum_panes || !bench_valid || moves < 0 || !interval_valid || interval < 0) {
    parser.showHelp(1);
  }

  const auto mode = mode_name == "router" ? Mode::router : Mode::activate;
  std::printf("mode %s, %d panes\n", qPrintable(mode_name), panes);
  std::fflush(stdout);

  try {
    QQmlEngine engine;
    Router router(engine, mode, panes);
    Bench bench(router, moves, std::chrono::milliseconds{interval}, parser.isSet(quit_option));
    router.show();
    if (moves > 0) {
      bench.start();
    }

    return application.exec();
  } catch (const std::exception &error) {
    std::fprintf(stderr, "input_router_dbg: %s\n", error.what());
    return 1;
  }
}
