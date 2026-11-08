#include "frame_fixture.hpp"
#include "gui_wait.hpp"
#include "qt/modal_reveal_layout.hpp"
#include <QGuiApplication>
#include <QPointer>
#include <QQuickWindow>
#include <QString>
#include <QTimer>
#include <QtCore/qobject.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <QtTest/QTest>
#include <QtTest/qtestcase.h>
#include <algorithm>
#include <memory>
#include <vector>

namespace {

using namespace telar::gui::qt;
using namespace telar::gui::test;

constexpr int wait_ms = 5000;
constexpr int window_width = 320;
constexpr int window_height = 200;

class ModalRevealTest final : public QObject {
  Q_OBJECT

  Q_SLOT static void entranceStartsAtZeroAndSettles() {
    QQuickWindow window;
    ModalRevealLayout item(window.contentItem());
    window.resize(window_width, window_height);
    QVERIFY(showComponentWindow(window, wait_ms));
    std::vector<qreal> samples;
    QObject::connect(&item, &ModalRevealLayout::frameChanged, &window, [&] {
      samples.push_back(item.reveal());
    });
    item.setGeneration(QStringLiteral("11"));
    item.setActive(true);
    QVERIFY(waitForGuiCondition([&] {
      return samples.size() >= 2 && item.reveal() == 1;
    },
                                wait_ms));
    QCOMPARE(samples.front(), qreal{0});
    QCOMPARE(samples.back(), qreal{1});
    QVERIFY(std::ranges::is_sorted(samples));
    QVERIFY(std::ranges::all_of(samples, [](qreal value) {
      return value >= 0 && value <= 1;
    }));
    const auto *timer = window.findChild<QTimer *>(QStringLiteral("agentStatusAnimation"));
    QVERIFY(timer != nullptr);
    QVERIFY(waitForGuiCondition([&] {
      return !timer->isActive();
    },
                                wait_ms));
  }

  Q_SLOT static void onlyANewGenerationRestartsTheEntrance() {
    QQuickWindow window;
    ModalRevealLayout item(window.contentItem());
    window.resize(window_width, window_height);
    QVERIFY(showComponentWindow(window, wait_ms));
    int zero_samples = 0;
    QObject::connect(&item, &ModalRevealLayout::frameChanged, &window, [&] {
      zero_samples += item.reveal() == 0;
    });
    item.setGeneration(QStringLiteral("11"));
    item.setActive(true);
    QVERIFY(waitForGuiCondition([&] {
      return zero_samples == 1 && item.reveal() == 1;
    },
                                wait_ms));
    item.setGeneration(QStringLiteral("11"));
    QCOMPARE(item.reveal(), qreal{1});
    QCOMPARE(zero_samples, 1);
    item.setGeneration(QStringLiteral("12"));
    QVERIFY(waitForGuiCondition([&] {
      return zero_samples == 2 && item.reveal() == 1;
    },
                                wait_ms));
    item.setActive(false);
    item.setGeneration(QString{});
    QCOMPARE(item.reveal(), qreal{1});
  }

  Q_SLOT static void destructionDuringTheFirstFrameRetiresTheClockEntry() {
    QQuickWindow window;
    window.resize(window_width, window_height);
    QVERIFY(showComponentWindow(window, wait_ms));
    auto item = std::make_unique<ModalRevealLayout>(window.contentItem());
    const QPointer<ModalRevealLayout> observer{item.get()};
    QObject::connect(item.get(), &ModalRevealLayout::frameChanged, &window, [&] {
      if (item->reveal() == 0) {
        item.reset();
      }
    });
    item->setGeneration(QStringLiteral("11"));
    item->setActive(true);
    QVERIFY(waitForGuiCondition([&] {
      return observer.isNull();
    },
                                wait_ms));
    QVERIFY(waitForSynchronizedFrame(window, wait_ms));
  }
};

}

QTEST_MAIN(ModalRevealTest)
#include "modal_reveal_test.moc"
