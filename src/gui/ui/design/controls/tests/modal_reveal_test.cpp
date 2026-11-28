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

import telar.gui.ui.design.controls;
import telar.gui.tests.frame_fixture;
import telar.gui.tests.gui_wait;
import telar.gui.tests.qt_case;
import telar.gui.qt;

namespace {
  using Qt::StringLiterals::operator""_s;

  using namespace telar::gui::qt;
  using namespace telar::gui::test;

  constexpr int wait_ms = 5000;
  constexpr int window_width = 320;
  constexpr int window_height = 200;

  class [[qt::object]] ModalRevealTest final : public QObject {
  public:
    static const QMetaObject staticMetaObject;
    const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

  private:
    [[qt::slot]] static void entranceStartsAtZeroAndSettles() {
      QQuickWindow window;
      ModalRevealLayout item(window.contentItem());

      window.resize(window_width, window_height);
      QVERIFY(showComponentWindow(window, wait_ms));
      std::vector<qreal> samples;

      QObject::connect(&item, &ModalRevealLayout::frameChanged, &window, [&] {
        samples.push_back(item.reveal());
      });

      item.setGeneration(u"11"_s);
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

      const auto* timer = window.findChild<QTimer*>(u"agentStatusAnimation"_s);

      QVERIFY(timer != nullptr);
      QVERIFY(waitForGuiCondition([&] {
        return !timer->isActive();
      },
          wait_ms));
    }

    [[qt::slot]] static void onlyANewGenerationRestartsTheEntrance() {
      QQuickWindow window;
      ModalRevealLayout item(window.contentItem());

      window.resize(window_width, window_height);
      QVERIFY(showComponentWindow(window, wait_ms));
      int zero_samples = 0;

      QObject::connect(&item, &ModalRevealLayout::frameChanged, &window, [&] {
        zero_samples += item.reveal() == 0;
      });

      item.setGeneration(u"11"_s);
      item.setActive(true);
      QVERIFY(waitForGuiCondition([&] {
        return zero_samples == 1 && item.reveal() == 1;
      },
          wait_ms));
      item.setGeneration(u"11"_s);
      QCOMPARE(item.reveal(), qreal{1});
      QCOMPARE(zero_samples, 1);
      item.setGeneration(u"12"_s);
      QVERIFY(waitForGuiCondition([&] {
        return zero_samples == 2 && item.reveal() == 1;
      },
          wait_ms));
      item.setActive(false);
      item.setGeneration(QString{});
      QCOMPARE(item.reveal(), qreal{1});
    }

    [[qt::slot]] static void destructionDuringTheFirstFrameRetiresTheClockEntry() {
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

      item->setGeneration(u"11"_s);
      item->setActive(true);
      QVERIFY(waitForGuiCondition([&] {
        return observer.isNull();
      },
          wait_ms));
      QVERIFY(waitForSynchronizedFrame(window, wait_ms));
    }
  };

  using telar::gui::test::QtCase;

  const QtCase<ModalRevealTest, "entranceStartsAtZeroAndSettles"> case_entrance_starts_at_zero_and_settles{"modal_reveal.entrance_starts_at_zero_and_settles"};
  const QtCase<ModalRevealTest, "onlyANewGenerationRestartsTheEntrance"> case_only_a_new_generation_restarts_the_entrance{"modal_reveal.only_a_new_generation_restarts_the_entrance"};
  const QtCase<ModalRevealTest, "destructionDuringTheFirstFrameRetiresTheClockEntry"> case_destruction_during_the_first_frame_retires_the_clock_entry{"modal_reveal.destruction_during_the_first_frame_retires_the_clock_entry"};

}

#ifndef TELAR_MOC_RUN
#include "modal_reveal_test.moc"
#endif
