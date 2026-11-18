#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "qml_fixture.hpp"
#include "ui/app/panes/terminal/history/layout/history_selection_layout.hpp"
#include <QDebug>
#include <QEvent>
#include <QMetaObject>
#include <QObject>
#include <QPointer>
#include <QQuickItem>
#include <QQuickWindow>
#include <QTimer>
#include <QVariant>
#include <QtCore/qnamespace.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtenvironmentvariables.h>
#include <QtCore/qtypes.h>
#include <QtTest/qtestcase.h>
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>

#pragma once

import telar.gui.foundation.system;
import telar.base.ds;

namespace telar::gui::test {

  // Record both threads without logging or requesting frames during the wait.
  class HistoryCardWaitTrace : public QObject {
  public:
    explicit HistoryCardWaitTrace(QQuickWindow& window)
        : window_(window),
          samples_(std::make_shared<Samples>()),
          timer_(window.findChild<QTimer*>(QStringLiteral("agentStatusAnimation"))),
          selection_(window.findChild<qt::HistorySelectionLayout*>()) {
      window_.installEventFilter(this);
      connections_.atMut(0) = connect(&window_, &QQuickWindow::afterAnimating, this, [this] {
        ++frames_;
        record(Phase::animation);
      });

      connections_.atMut(1) = connect(&window_, &QQuickWindow::afterSynchronizing, this, [samples = samples_] {
        samples->record({.phase = Phase::synchronized, .timestamp = system::AwakeClock::nowNanoseconds()});
      },
          Qt::DirectConnection);
      connections_.atMut(2) = connect(&window_, &QQuickWindow::frameSwapped, this, [samples = samples_] {
        samples->record({.phase = Phase::swapped, .timestamp = system::AwakeClock::nowNanoseconds()});
      },
          Qt::DirectConnection);
      if (!timer_.isNull()) {
        connections_.atMut(3) = connect(timer_, &QTimer::timeout, this, [this] {
          record(Phase::timer);
        });
      }

      record(Phase::begin);
    }

    ~HistoryCardWaitTrace() override {
      window_.removeEventFilter(this);
      for (const auto& connection : connections_) {
        QObject::disconnect(connection);
      }

      if (!QTest::currentTestFailed() && !qEnvironmentVariableIsSet("TELAR_GUI_TEST_HISTORY_TRACE")) {
        return;
      }

      const auto rows = visualItems(*window_.contentItem(), QStringLiteral("historyResult"));

      qInfo() << "History card wait diagnostic: frames" << frames_ << "active" << window_.isActive() << "exposed" << window_.isExposed() << "rows" << rows.size() << "clock active" << (!timer_.isNull() && timer_->isActive()) << "remaining ms" << (timer_.isNull() ? 0 : timer_->remainingTime());
      for (auto* row : rows) {
        for (const auto* card : visualItems(*row, QStringLiteral("historyRow"))) {
          qInfo() << "History card state: index" << row->property("index") << "selected" << card->property("selected") << "open" << card->property("open") << "height" << card->height() << "visible" << card->isVisible();
        }
      }

      const std::scoped_lock lock{samples_->mutex};
      const auto count = std::min(samples_->count, samples_->values.size());
      const auto begin = samples_->count - count;

      for (std::size_t index = begin; index < samples_->count; ++index) {
        const auto& sample = samples_->values[index % samples_->values.size()];

        qInfo() << "History frame trace: phase" << static_cast<int>(sample.phase) << "elapsed ns" << sample.timestamp - samples_->start << "open" << sample.open << "leaving" << sample.leaving << "timer ms" << sample.timer_ms;
      }
    }

    HistoryCardWaitTrace(const HistoryCardWaitTrace&) = delete;
    HistoryCardWaitTrace& operator=(const HistoryCardWaitTrace&) = delete;
    HistoryCardWaitTrace(HistoryCardWaitTrace&&) = delete;
    HistoryCardWaitTrace& operator=(HistoryCardWaitTrace&&) = delete;

    bool eventFilter(QObject* watched, QEvent* event) override {
      if (event->type() == QEvent::UpdateRequest) {
        record(Phase::update);
      } else if (event->type() == QEvent::Expose) {
        record(Phase::expose);
      }

      return QObject::eventFilter(watched, event);
    }

  private:
    enum class Phase : std::uint8_t {
      begin,
      update,
      expose,
      timer,
      animation,
      synchronized,
      swapped,
    };

    struct Sample {
      Phase phase = Phase::begin;
      std::uint64_t timestamp = 0;
      qreal open = -1;
      qreal leaving = -1;
      int timer_ms = -1;
    };

    struct Samples {
      static constexpr std::size_t capacity = 512;

      void record(Sample sample) {
        const std::scoped_lock lock{mutex};

        values.atMut(count++ % values.size()) = sample;
      }

      std::mutex mutex;
      ds::Array<Sample, capacity> values{};
      std::size_t count = 0;
      std::uint64_t start = system::AwakeClock::nowNanoseconds();
    };

    void record(Phase phase) {
      samples_->record({.phase = phase, .timestamp = system::AwakeClock::nowNanoseconds(), .open = selection_.isNull() ? -1 : selection_->selectedOpen(), .leaving = selection_.isNull() ? -1 : selection_->leavingOpen(), .timer_ms = timer_.isNull() ? -1 : timer_->remainingTime()});
    }

    QQuickWindow& window_;
    std::shared_ptr<Samples> samples_;
    QPointer<QTimer> timer_;
    QPointer<qt::HistorySelectionLayout> selection_;
    ds::Array<QMetaObject::Connection, 4> connections_;
    int frames_ = 0;
  };

}
