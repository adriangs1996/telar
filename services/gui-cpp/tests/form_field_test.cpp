#include "clipboard_fixture.hpp"
#include "frame_fixture.hpp"
#include "platform/window_activation.hpp"
#include "qml_fixture.hpp"
#include "qt/native_form_field.hpp"
#include "qt/form_input_context.hpp"
#include "qt/projection.hpp"
#include "text/utf16_prefix.hpp"
#include "text/utf8.hpp"
#include "ui/bundled_fonts.hpp"
#include <QClipboard>
#include <QFont>
#include <QGuiApplication>
#include <QInputMethodEvent>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRegularExpression>
#include <QSignalSpy>
#include <QString>
#include <QStringView>
#include <QVariantMap>
#include <QtCore/qcoreapplication.h>
#include <QtCore/qcoreevent.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qobject.h>
#include <QtCore/qscopeguard.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <QtTest/QTest>
#include <QtTest/qtestcase.h>
#include <QtTest/qtestkeyboard.h>
#include <QtTest/qtestmouse.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <memory>
#include <string_view>
#include <utility>

namespace {

using namespace telar::gui::qt;
using namespace telar::gui::test;

constexpr int wait_ms = 5000;
constexpr int field_width = 320;
constexpr int field_height = 52;
constexpr int body_pixels = 13;

class FieldFixture {
public:
  FieldFixture()
      : item(createChrome(engine, QStringLiteral("FormTextField"), {
                                                                       {QStringLiteral("colors"), themeColors({})},
                                                                       {QStringLiteral("typography"), QVariantMap{{QStringLiteral("body"), body_pixels}, {QStringLiteral("primaryFamily"), QStringLiteral("JetBrains Mono")}, {QStringLiteral("primaryStyle"), QString{}}}},
                                                                       {QStringLiteral("width"), field_width},
                                                                       {QStringLiteral("height"), field_height},
                                                                   })) {
    item->setParentItem(window.contentItem());
    window.resize(field_width, field_height);
  }

  [[nodiscard]] NativeFormField &field() const {
    return *qobject_cast<NativeFormField *>(item.get());
  }

  QQuickWindow window;
  QQmlEngine engine;
  std::unique_ptr<QQuickItem> item;
};

class FormFieldTest final : public QObject {
  Q_OBJECT

  Q_SLOT static void initTestCase() {
    ui::bundledFonts();
    QGuiApplication::setFont(QFont{QStringLiteral("IBM Plex Sans")});
  }

  Q_SLOT static void init() {
    QTest::failOnWarning(QRegularExpression{QStringLiteral(".*")});
  }

  Q_SLOT static void formGeometryUsesTheBodyCellGrid() {
    FieldFixture fixture;
    auto &field = fixture.field();
    QVERIFY(showComponentWindow(fixture.window, wait_ms));
    field.setText(QStringLiteral("telar"));
    QTRY_VERIFY_WITH_TIMEOUT(field.layout().value(QStringLiteral("available")).toBool(), wait_ms);
    const auto grid = field.layout().value(QStringLiteral("grid")).toMap();
    const auto content = field.layout().value(QStringLiteral("content")).toRectF();
    constexpr qreal inset = 12;
    QCOMPARE(content.x(), inset);
    QCOMPARE(content.width(), field_width - (inset * 2));
    QCOMPARE(grid.value(QStringLiteral("pixelHeight")).toDouble() * fixture.window.effectiveDevicePixelRatio(), std::round(body_pixels * fixture.window.effectiveDevicePixelRatio()));
    const auto density = fixture.window.effectiveDevicePixelRatio();
    const auto line_height = grid.value(QStringLiteral("cellHeight")).toDouble();
    QCOMPARE(content.y(), std::floor(((field_height * density) - (line_height * density)) / 2) / density);
    const QSignalSpy edited{&field, &NativeFormField::textEdited};
    field.select(1, 4);
    QCOMPARE(field.selectedText(), QStringLiteral("ela"));
    QVERIFY(waitForSynchronizedFrame(fixture.window, wait_ms));
    const auto selection = field.layout().value(QStringLiteral("selection")).toRectF();
    const auto caret = field.layout().value(QStringLiteral("caret")).toRectF();
    const auto cell = grid.value(QStringLiteral("cellWidth")).toDouble();
    QCOMPARE(selection.x(), content.x() + cell);
    QCOMPARE(selection.width(), 3 * cell);
    QCOMPARE(caret.x(), content.x() + (4 * cell));
    QCOMPARE(caret.width(), std::max(qreal{1}, density) / density);
    QCOMPARE(edited.size(), 0);
  }

  Q_SLOT static void keyboardMovesAndDeletesWholeGraphemes() {
    FieldFixture fixture;
    auto &field = fixture.field();
    QVERIFY(showComponentWindow(fixture.window, wait_ms));
    field.forceActiveFocus();
    field.setText(QStringLiteral("a👩‍💻"));
    QTest::keyClick(&fixture.window, Qt::Key_Backspace);
    QCOMPARE(field.text(), QStringLiteral("a"));
    QTest::keyClick(&fixture.window, Qt::Key_A, Qt::ControlModifier);
    QCOMPARE(field.selectedText(), QStringLiteral("a"));
    QKeyEvent composed{QEvent::KeyPress, Qt::Key_unknown, Qt::NoModifier, QStringLiteral("é")};
    QCoreApplication::sendEvent(&field, &composed);
    QCOMPARE(field.text(), QStringLiteral("é"));
    QTest::keyClick(&fixture.window, Qt::Key_Left, Qt::ShiftModifier);
    QCOMPARE(field.selectedText(), QStringLiteral("é"));
    QTest::keyClick(&fixture.window, Qt::Key_Right, Qt::ControlModifier);
    QCOMPARE(field.selectionStart(), field.selectionEnd());
    QCOMPARE(field.cursorPosition(), static_cast<int>(field.text().size()));
  }

  Q_SLOT static void compositionKeepsCommittedTextUntilCommit() {
    FieldFixture fixture;
    auto &field = fixture.field();
    QVERIFY(showComponentWindow(fixture.window, wait_ms));
    activateWindow(fixture.window);
    QTRY_VERIFY_WITH_TIMEOUT(fixture.window.isActive(), wait_ms);
    field.forceActiveFocus();
    field.setText(QStringLiteral("before after"));
    const auto selected_length = static_cast<int>(QStringLiteral("before").size());
    field.select(0, selected_length);
    const QSignalSpy edited{&field, &NativeFormField::textEdited};
    QInputMethodEvent preedit{QStringLiteral("中"), {{QInputMethodEvent::Cursor, 1, 1, {}}}};
    QCoreApplication::sendEvent(&field, &preedit);
    QCOMPARE(field.text(), QStringLiteral("before after"));
    QCOMPARE(field.selectedText(), QStringLiteral("before"));
    QCOMPARE(field.inputMethodQuery(Qt::ImAbsolutePosition).toInt(), 0);
    QCOMPARE(field.inputMethodQuery(Qt::ImCursorPosition).toInt(), 0);
    QCOMPARE(field.inputMethodQuery(Qt::ImAnchorPosition).toInt(), 0);
    QCOMPARE(field.inputMethodQuery(Qt::ImSurroundingText).toString(), QStringLiteral(" after"));
    QCOMPARE(field.inputMethodQuery(Qt::ImCurrentSelection).toString(), QString{});
    QCOMPARE(field.inputMethodQuery(Qt::ImTextBeforeCursor).toString(), QString{});
    QCOMPARE(field.inputMethodQuery(Qt::ImTextAfterCursor).toString(), QStringLiteral(" after"));
    QCOMPARE(edited.size(), 0);
    QTRY_VERIFY_WITH_TIMEOUT(field.layout().value(QStringLiteral("composing")).toBool(), wait_ms);
    QCOMPARE(field.layout().value(QStringLiteral("text")).toString(), QStringLiteral("中 after"));
    QInputMethodEvent cancel;
    QCoreApplication::sendEvent(&field, &cancel);
    QCOMPARE(field.text(), QStringLiteral("before after"));
    QCOMPARE(field.selectedText(), QStringLiteral("before"));
    QInputMethodEvent commit;
    commit.setCommitString(QStringLiteral("🧵"));
    QCoreApplication::sendEvent(&field, &commit);
    QCOMPARE(field.text(), QStringLiteral("🧵 after"));
    QCOMPARE(edited.size(), 1);
    field.setText(QStringLiteral("ab after"));
    field.setCursorPosition(2);
    QInputMethodEvent replacement;
    replacement.setCommitString(QStringLiteral("X"), -1, 1);
    QCoreApplication::sendEvent(&field, &replacement);
    QCOMPARE(field.text(), QStringLiteral("aX after"));
    QInputMethodEvent selected{QString{}, {{QInputMethodEvent::Selection, 0, 2, {}}}};
    QCoreApplication::sendEvent(&field, &selected);
    QCOMPARE(field.selectedText(), QStringLiteral("aX"));
  }

  Q_SLOT static void inputContextProjectsSelectionAndProvisionalReplacement() {
    const auto text = QStringLiteral("a🧵b");
    const auto first = static_cast<int>(QStringLiteral("a").size());
    const auto last = static_cast<int>(QStringLiteral("a🧵").size());
    const auto confirmed = FormInputContext::capture(text, last, first);
    QCOMPARE(confirmed.text, text);
    QCOMPARE(confirmed.cursor, last);
    QCOMPARE(confirmed.anchor, first);
    QCOMPARE(confirmed.selectedText(), QStringLiteral("🧵"));
    QCOMPARE(confirmed.beforeCursor(), QStringLiteral("a🧵"));
    QCOMPARE(confirmed.afterCursor(), QStringLiteral("b"));

    const auto backward = FormInputContext::capture(text, first, last);
    QCOMPARE(backward.selectedText(), QStringLiteral("🧵"));
    QCOMPARE(backward.beforeCursor(), QStringLiteral("a"));
    QCOMPARE(backward.afterCursor(), QStringLiteral("🧵b"));

    const auto provisional = FormInputContext::capture(text, last, first, FormInputContext::Replacement{.first = first, .last = last});
    QCOMPARE(provisional.text, QStringLiteral("ab"));
    QCOMPARE(provisional.cursor, first);
    QCOMPARE(provisional.anchor, first);
    QVERIFY(provisional.selectedText().isEmpty());
    QCOMPARE(provisional.beforeCursor(), QStringLiteral("a"));
    QCOMPARE(provisional.afterCursor(), QStringLiteral("b"));
    QCOMPARE(text, QStringLiteral("a🧵b"));
  }

  Q_SLOT static void cancellationAndFocusLossPreserveCommittedSelection() {
    const FieldFixture fixture;
    auto &field = fixture.field();
    const auto committed = QStringLiteral("before after");
    const auto selected = QStringLiteral("before");
    field.setText(committed);
    field.select(0, static_cast<int>(selected.size()));
    const QSignalSpy edited{&field, &NativeFormField::textEdited};
    QInputMethodEvent preedit{QStringLiteral("中"), {{QInputMethodEvent::Cursor, 1, 1, {}}}};
    QCoreApplication::sendEvent(&field, &preedit);
    QVERIFY(field.cancelComposition());
    QVERIFY(!field.cancelComposition());
    QCOMPARE(field.text(), committed);
    QCOMPARE(field.selectedText(), selected);
    QCOMPARE(edited.size(), 0);

    QCoreApplication::sendEvent(&field, &preedit);
    QFocusEvent focus_lost{QEvent::FocusOut};
    QCoreApplication::sendEvent(&field, &focus_lost);
    QVERIFY(!field.cancelComposition());
    QCOMPARE(field.text(), committed);
    QCOMPARE(field.selectedText(), selected);
    QCOMPARE(edited.size(), 0);
  }

  Q_SLOT static void pasteNormalizesLinesAndBoundsUtf8Bytes() {
    auto *clipboard = QGuiApplication::clipboard();
    auto saved = copyClipboard();
    const auto restore = qScopeGuard([clipboard, saved = std::move(saved)] mutable {
      clipboard->setMimeData(saved.release());
    });
    FieldFixture fixture;
    auto &field = fixture.field();
    QVERIFY(showComponentWindow(fixture.window, wait_ms));
    constexpr int maximum_bytes = 8;
    field.setMaximumBytes(maximum_bytes);
    clipboard->setText(QStringLiteral("a\r\nb\rc\nd"));
    field.paste();
    QCOMPARE(field.text(), QStringLiteral("a b c d"));
    field.selectAll();
    clipboard->setText(QStringLiteral("1234567🧵"));
    const QSignalSpy limited{&field, &NativeFormField::limitReached};
    field.paste();
    QCOMPARE(field.text(), QStringLiteral("1234567"));
    QCOMPARE(limited.size(), 1);
    QCOMPARE(limited.front().front().toULongLong(), static_cast<qulonglong>(QStringLiteral("1234567🧵").toUtf8().size()));
    field.setText(QStringLiteral("a🧵"));
    field.select(1, 3);
    field.copy();
    QCOMPARE(clipboard->text(), QStringLiteral("🧵"));
    field.cut();
    QCOMPARE(field.text(), QStringLiteral("a"));
  }

  Q_SLOT static void utf16PrefixMatchesQtEncodingAndScalarBoundaries() {
    QString text;
    for (std::uint32_t unit = 0; unit <= std::numeric_limits<char16_t>::max(); ++unit) {
      text.append(QChar{static_cast<char16_t>(unit)});
    }

    const auto high = QChar{telar::gui::Utf16Prefix::first_high_surrogate};
    const auto low = QChar{telar::gui::Utf16Prefix::first_low_surrogate};
    const std::array samples{text, QStringLiteral("aé中🧵z"), QString{high}, QString{low}, QString{high} + low, QString{low} + high, QStringLiteral("a") + high + QStringLiteral("🧵z"), QStringLiteral("a") + low + QStringLiteral("🧵z")};
    constexpr std::array<std::size_t, 10> capacities{0, 1, 2, 3, 4, 8, 127, 128, 256, 512};
    for (const auto &sample : samples) {
      const auto encoded = sample.toUtf8();
      const std::string_view source{encoded.constData(), static_cast<std::size_t>(encoded.size())};
      for (const auto capacity : capacities) {
        const auto fitted = telar::gui::Utf16Prefix::fit(QStringView{sample}, capacity);
        const auto expected = telar::runtime::utf8Prefix(source, capacity);
        const auto prefix = sample.first(static_cast<qsizetype>(fitted.units)).toUtf8();
        QCOMPARE(fitted.requested_bytes, static_cast<std::size_t>(encoded.size()));
        QCOMPARE(fitted.bytes, expected.size());
        QCOMPARE(prefix, QByteArray(expected.data(), static_cast<qsizetype>(expected.size())));
      }
    }
  }

  Q_SLOT static void pointerUsesCellMidpointsAndPreservesWholeGraphemes() {
    FieldFixture fixture;
    auto &field = fixture.field();
    QVERIFY(showComponentWindow(fixture.window, wait_ms));
    field.setText(QStringLiteral("a🧵b"));
    QVERIFY(waitForSynchronizedFrame(fixture.window, wait_ms));
    const auto content = field.layout().value(QStringLiteral("content")).toRectF();
    const auto cell = field.layout().value(QStringLiteral("grid")).toMap().value(QStringLiteral("cellWidth")).toDouble();
    constexpr qreal before_midpoint = 1.75;
    constexpr qreal after_midpoint = 2.25;
    const auto left = field.mapToScene(QPointF{content.x() + (before_midpoint * cell), content.center().y()}).toPoint();
    const auto right = field.mapToScene(QPointF{content.x() + (after_midpoint * cell), content.center().y()}).toPoint();
    QTest::mouseClick(&fixture.window, Qt::LeftButton, Qt::NoModifier, left);
    QCOMPARE(field.cursorPosition(), 1);
    QTest::mouseClick(&fixture.window, Qt::LeftButton, Qt::NoModifier, right);
    QCOMPARE(field.cursorPosition(), 3);
    QTest::mouseDClick(&fixture.window, Qt::LeftButton, Qt::NoModifier, left);
    QTest::mouseRelease(&fixture.window, Qt::LeftButton, Qt::NoModifier, left);
    QVERIFY(field.selectedText().isEmpty());
    QCOMPARE(field.cursorPosition(), 1);
    QTest::mousePress(&fixture.window, Qt::LeftButton, Qt::NoModifier, left);
    QTest::mouseMove(&fixture.window, right);
    QTest::mouseRelease(&fixture.window, Qt::LeftButton, Qt::NoModifier, right);
    QCOMPARE(field.selectedText(), QStringLiteral("🧵"));
  }
};

}

QTEST_MAIN(FormFieldTest)
#include "form_field_test.moc"
