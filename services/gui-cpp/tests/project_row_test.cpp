#include "application/records.hpp"
#include "application/workspace_replica.hpp"
#include "core/configuration.hpp"
#include "core/memory.hpp"
#include "core/metrics.hpp"
#include "qml_fixture.hpp"
#include "presentation/chrome_style.hpp"
#include "qt/list_model.hpp"
#include "qt/project_projection.hpp"
#include "qt/projection.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "qt/bundled_fonts.hpp"
#include <QAbstractItemModel>
#include <QColor>
#include <QGuiApplication>
#include <QMetaMethod>
#include <QPointF>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include <QSignalSpy>
#include <QString>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <QtTest/QTest>
#include <QtTest/qtestcase.h>
#include <QtTest/qtestmouse.h>
#include <array>
#include <span>

namespace {

using namespace telar;
using namespace telar::gui;
using namespace telar::gui::qt;
using namespace telar::gui::test;

constexpr int wait_ms = 5000;
constexpr qreal row_width = 263;
constexpr qreal row_height = 52;

QVariantMap project() {
  return {
      {QStringLiteral("key"), QStringLiteral("workspace:1")},
      {QStringLiteral("name"), QStringLiteral("A long project title that needs fitting")},
      {QStringLiteral("path"), QStringLiteral("/project")},
      {QStringLiteral("detail"), QStringLiteral("\u2387 5 \u00b7 \u25cc 2 \u2713 1  /project")},
      {QStringLiteral("attention"), QStringLiteral("! 2")},
      {QStringLiteral("attentionColor"), QStringLiteral("red")},
      {QStringLiteral("selected"), true},
  };
}

QVariantMap properties() {
  const ChromeMetrics chrome;

  const QVariantMap typography{
      {QStringLiteral("body"), chrome.body},
      {QStringLiteral("small"), chrome.small},
      {QStringLiteral("bodyRow"), ChromeMetrics::lineHeight(chrome.body)},
      {QStringLiteral("smallRow"), ChromeMetrics::lineHeight(chrome.small)},
  };

  return {
      {QStringLiteral("width"), row_width},
      {QStringLiteral("height"), row_height},
      {QStringLiteral("record"), project()},
      {QStringLiteral("colors"), themeColors(Configuration{})},
      {QStringLiteral("typography"), typography},
  };
}

class ProjectRowTest final : public QObject {
  Q_OBJECT

private:
  Q_SLOT static void initTestCase() {
    bundledFonts();
  }

  Q_SLOT static void projectProjectionKeepsSummaryAndUrgentColor() {
    SystemAllocator memory;
    WorkspaceReplica replica{memory};
    const std::array entries{WorkspaceListEntry{.workspace = 1, .name = "project", .path = "/project"}, WorkspaceListEntry{.workspace = 2, .name = "task", .path = "/task"}};
    const std::array tasks{WorktreeListEntry{.worktree = 1, .source = 1, .workspace = 2, .path = "/task", .branch = "worktree-task"}};
    replica.apply({.revision = 1, .entries = entries, .worktrees = tasks});
    std::array agents{Agent{memory}, Agent{memory}};
    agents[0].location.workspace.id = 2;
    agents[0].status = AgentStatus::working;
    agents[1].location.workspace.id = 1;
    agents[1].status = AgentStatus::failed;
    const auto record = projectRecord(replica.projects().front(), replica, std::span<const Agent<SystemAllocator>>{agents}, true);
    QCOMPARE(record.value(QStringLiteral("detail")).toString(), QStringLiteral("\u2387 1 \u00b7 \u25cc 1 \u2713 0  /project"));
    QCOMPARE(record.value(QStringLiteral("attention")).toString(), QStringLiteral("! 1"));
    QCOMPARE(record.value(QStringLiteral("attentionColor")).toString(), QStringLiteral("red"));
    QCOMPARE(record.value(QStringLiteral("path")).toString(), QStringLiteral("/project"));
  }

  Q_SLOT static void standaloneRowReservesAttentionAndEmitsIdentity() {
    QQuickWindow window;
    QQmlEngine engine;
    const auto row = createChrome(engine, QStringLiteral("ProjectRow"), properties());
    row->setParentItem(window.contentItem());
    window.resize(static_cast<int>(row_width), static_cast<int>(row_height));
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    const auto *title = row->findChild<QQuickItem *>(QStringLiteral("projectTitle"));
    const auto *attention = row->findChild<QQuickItem *>(QStringLiteral("projectAttention"));
    const auto *detail = row->findChild<QQuickItem *>(QStringLiteral("projectDetail"));
    QVERIFY(title != nullptr && attention != nullptr && detail != nullptr);
    QTRY_VERIFY_WITH_TIMEOUT(attention->width() > 0, wait_ms);
    constexpr qreal attention_gap = 8;
    QCOMPARE(title->x() + title->width() + attention_gap, attention->x());
    QCOMPARE(detail->width(), title->width() + attention->width() + attention_gap);
    const auto colors = themeColors(Configuration{});
    QCOMPARE(attention->property("color").value<QColor>(), colors.value(QStringLiteral("red")).value<QColor>());

    const auto signal = row->metaObject()->indexOfSignal("selected(QString)");
    QVERIFY(signal >= 0);
    const QSignalSpy selected{row.get(), row->metaObject()->method(signal)};
    QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier, row->mapToScene({row->width() / 2, row->height() / 2}).toPoint());
    QCOMPARE(selected.count(), 1);
    QCOMPARE(selected.front().front().toString(), QStringLiteral("workspace:1"));

    auto record = project();
    record.insert(QStringLiteral("selected"), false);
    row->setProperty("record", record);
    QCOMPARE(attention->property("color").value<QColor>(), colors.value(QStringLiteral("red")).value<QColor>());
    QCOMPARE(title->property("color").value<QColor>(), colors.value(QStringLiteral("subtext0")).value<QColor>());
    record.insert(QStringLiteral("attention"), QString{});
    row->setProperty("record", record);
    QTRY_VERIFY_WITH_TIMEOUT(!attention->isVisible(), wait_ms);
    QCOMPARE(title->width(), detail->width());
    QCOMPARE(detail->property("text").toString(), project().value(QStringLiteral("detail")).toString());

    constexpr qreal icon_only_width = 20;
    row->setWidth(icon_only_width);
    QCOMPARE(title->width(), 0);
    QCOMPARE(detail->width(), 0);
    QCOMPARE(attention->width(), 0);
  }

  Q_SLOT static void selectionUsesANeutralSurfaceWithoutHover_data() {
    QTest::addColumn<QColor>("ink");
    QTest::addColumn<qreal>("ratio");
    QTest::newRow("dark") << QColor{QStringLiteral("#aba8b6")} << qreal{1};
    QTest::newRow("light") << QColor{QStringLiteral("#202020")} << qreal{1};
    QTest::newRow("fractional") << QColor{QStringLiteral("#aba8b6")} << qreal{1.5};
    QTest::newRow("double") << QColor{QStringLiteral("#202020")} << qreal{2};
  }

  Q_SLOT static void selectionUsesANeutralSurfaceWithoutHover() {
    QFETCH(QColor, ink);
    QFETCH(qreal, ratio);
    QQmlEngine engine;
    auto setup = properties();
    auto colors = setup.value(QStringLiteral("colors")).toMap();
    colors.insert(QStringLiteral("text"), ink);
    setup.insert(QStringLiteral("colors"), colors);
    setup.insert(QStringLiteral("ratio"), ratio);
    const auto row = createChrome(engine, QStringLiteral("ProjectRow"), setup);
    const auto *outline = row->findChild<QQuickItem *>(QStringLiteral("projectSelectionOutline"));
    QVERIFY(outline != nullptr);
    QVERIFY(outline->isVisible());
    const auto selected = row->property("color").value<QColor>();
    auto expected = ink;
    expected.setAlphaF(telar::gui::ChromeStyle::selection_alpha);
    QCOMPARE(selected, expected);
    QCOMPARE(row->property("radius").toReal(), telar::gui::ChromeStyle::surface_radius * ratio);
    auto record = project();
    record.insert(QStringLiteral("selected"), false);
    QVERIFY(row->setProperty("record", record));
    QVERIFY(!outline->isVisible());
    QCOMPARE(row->property("color").value<QColor>().alpha(), 0);
  }

  Q_SLOT static void rowShowsThePointingCursor() {
    QQuickWindow window;
    QQmlEngine engine;
    const auto row = createChrome(engine, QStringLiteral("ProjectRow"), properties());
    row->setParentItem(window.contentItem());
    window.resize(static_cast<int>(row_width), static_cast<int>(row_height));
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    QTest::mouseMove(&window, row->mapToScene({row->width() / 2, row->height() / 2}).toPoint());
    QTRY_COMPARE_WITH_TIMEOUT(window.cursor().shape(), Qt::PointingHandCursor, wait_ms);
  }

  Q_SLOT static void projectListBindsAndUpdatesIndependentRows() {
    QQuickWindow window;
    QQmlEngine engine;
    ListModel model;
    model.reconcile({project()});
    auto setup = properties();
    setup.remove(QStringLiteral("record"));
    setup.insert(QStringLiteral("rowHeight"), row_height);
    setup.insert(QStringLiteral("model"), QVariant::fromValue(static_cast<QAbstractItemModel *>(&model)));
    const auto list = createChrome(engine, QStringLiteral("WorkspaceList"), setup);
    list->setParentItem(window.contentItem());
    window.resize(static_cast<int>(row_width), static_cast<int>(row_height));
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(visualItems(*list, QStringLiteral("projectDetail")).size(), 1, wait_ms);
    const auto *detail = visualItems(*list, QStringLiteral("projectDetail")).front();
    QCOMPARE(detail->property("text").toString(), project().value(QStringLiteral("detail")).toString());
    auto updated = project();
    updated.insert(QStringLiteral("detail"), QStringLiteral("/plain/project"));
    updated.insert(QStringLiteral("attention"), QString{});
    model.reconcile({updated});
    QTRY_COMPARE_WITH_TIMEOUT(detail->property("text").toString(), QStringLiteral("/plain/project"), wait_ms);
    QCOMPARE(visualItems(*list, QStringLiteral("projectAttention")).front()->isVisible(), false);
  }
};

}

int main(int argc, char **argv) {
  const QGuiApplication application{argc, argv};
  ProjectRowTest test;

  return QTest::qExec(&test, argc, argv);
}

#include "project_row_test.moc"
