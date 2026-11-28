#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif
#include "platform/window_activation.hpp"
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
#include <QtCore/qstringliteral.h>
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
#include <optional>
#include <string_view>
#include <utility>

import telar.base.text.utf8;
import telar.gui.ui.design.controls;
import telar.gui.ui.kit.fonts;
import telar.gui.ui.kit.models;
import telar.gui.ui.kit.text;
import telar.gui.tests.clipboard_fixture;
import telar.gui.tests.frame_fixture;
import telar.gui.tests.qml_fixture;
import telar.gui.tests.qt_case;
import telar.base.ds;
import telar.gui.foundation.text;
import telar.gui.qt;

namespace {
  using Qt::StringLiterals::operator""_s;

  using namespace telar::gui::qt;
  using namespace telar::gui::test;

  constexpr int wait_ms = 5000;
  constexpr int field_width = 320;
  constexpr int field_height = 52;
  constexpr int body_pixels = 13;

  class FieldFixture {
  public:
    FieldFixture()
        : item(createChrome(engine, u"FormTextField"_s, {
                                                            {u"colors"_s, themeColors({})},
                                                            {u"typography"_s, QVariantMap{{u"body"_s, body_pixels}, {u"primaryFamily"_s, u"JetBrains Mono"_s}, {u"primaryStyle"_s, QString{}}}},
                                                            {u"width"_s, field_width},
                                                            {u"height"_s, field_height},
                                                        })) {
      item->setParentItem(window.contentItem());
      window.resize(field_width, field_height);
    }

    [[nodiscard]] NativeFormField& field() const {
      return *qobject_cast<NativeFormField*>(item.get());
    }

    QQuickWindow window;
    QQmlEngine engine;
    std::unique_ptr<QQuickItem> item;
  };

  class [[qt::object]] FormFieldTest final : public QObject {
  public:
    static const QMetaObject staticMetaObject;
    const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

  private:
    [[qt::slot]] static void initTestCase() {
      bundledFonts();
      QGuiApplication::setFont(QFont{u"IBM Plex Sans"_s});
    }

    [[qt::slot]] static void init() {
      QTest::failOnWarning(QRegularExpression{u".*"_s});
    }

    [[qt::slot]] static void formGeometryUsesTheBodyCellGrid() {
      FieldFixture fixture;
      auto& field = fixture.field();

      QVERIFY(showComponentWindow(fixture.window, wait_ms));
      field.setText(u"telar"_s);
      QTRY_VERIFY_WITH_TIMEOUT(field.layout().value(u"available"_s).toBool(), wait_ms);
      const auto grid = field.layout().value(u"grid"_s).toMap();
      const auto content = field.layout().value(u"content"_s).toRectF();
      constexpr qreal inset = 12;

      QCOMPARE(content.x(), inset);
      QCOMPARE(content.width(), field_width - (inset * 2));
      QCOMPARE(grid.value(u"pixelHeight"_s).toDouble() * fixture.window.effectiveDevicePixelRatio(), std::round(body_pixels * fixture.window.effectiveDevicePixelRatio()));
      const auto density = fixture.window.effectiveDevicePixelRatio();
      const auto line_height = grid.value(u"cellHeight"_s).toDouble();

      QCOMPARE(content.y(), std::floor(((field_height * density) - (line_height * density)) / 2) / density);
      const QSignalSpy edited{&field, &NativeFormField::textEdited};

      field.select(1, 4);
      QCOMPARE(field.selectedText(), u"ela"_s);
      QVERIFY(waitForSynchronizedFrame(fixture.window, wait_ms));
      const auto selection = field.layout().value(u"selection"_s).toRectF();
      const auto caret = field.layout().value(u"caret"_s).toRectF();
      const auto cell = grid.value(u"cellWidth"_s).toDouble();

      QCOMPARE(selection.x(), content.x() + cell);
      QCOMPARE(selection.width(), 3 * cell);
      QCOMPARE(caret.x(), content.x() + (4 * cell));
      QCOMPARE(caret.width(), std::max(qreal{1}, density) / density);
      QCOMPARE(edited.size(), 0);
    }

    [[qt::slot]] static void keyboardMovesAndDeletesWholeGraphemes() {
      FieldFixture fixture;
      auto& field = fixture.field();

      QVERIFY(showComponentWindow(fixture.window, wait_ms));
      field.forceActiveFocus();
      field.setText(u"a👩‍💻"_s);
      QTest::keyClick(&fixture.window, Qt::Key_Backspace);
      QCOMPARE(field.text(), u"a"_s);
      QTest::keyClick(&fixture.window, Qt::Key_A, Qt::ControlModifier);
      QCOMPARE(field.selectedText(), u"a"_s);
      QKeyEvent composed{QEvent::KeyPress, Qt::Key_unknown, Qt::NoModifier, u"é"_s};

      QCoreApplication::sendEvent(&field, &composed);
      QCOMPARE(field.text(), u"é"_s);
      QTest::keyClick(&fixture.window, Qt::Key_Left, Qt::ShiftModifier);
      QCOMPARE(field.selectedText(), u"é"_s);
      QTest::keyClick(&fixture.window, Qt::Key_Right, Qt::ControlModifier);
      QCOMPARE(field.selectionStart(), field.selectionEnd());
      QCOMPARE(field.cursorPosition(), static_cast<int>(field.text().size()));
    }

    [[qt::slot]] static void compositionKeepsCommittedTextUntilCommit() {
      FieldFixture fixture;
      auto& field = fixture.field();

      QVERIFY(showComponentWindow(fixture.window, wait_ms));
      activateWindow(fixture.window);
      QTRY_VERIFY_WITH_TIMEOUT(fixture.window.isActive(), wait_ms);
      field.forceActiveFocus();
      field.setText(u"before after"_s);
      const auto selected_length = static_cast<int>(u"before"_s.size());

      field.select(0, selected_length);
      const QSignalSpy edited{&field, &NativeFormField::textEdited};
      QInputMethodEvent preedit{u"中"_s, {{QInputMethodEvent::Cursor, 1, 1, {}}}};

      QCoreApplication::sendEvent(&field, &preedit);
      QCOMPARE(field.text(), u"before after"_s);
      QCOMPARE(field.selectedText(), u"before"_s);
      QCOMPARE(field.inputMethodQuery(Qt::ImAbsolutePosition).toInt(), 0);
      QCOMPARE(field.inputMethodQuery(Qt::ImCursorPosition).toInt(), 0);
      QCOMPARE(field.inputMethodQuery(Qt::ImAnchorPosition).toInt(), 0);
      QCOMPARE(field.inputMethodQuery(Qt::ImSurroundingText).toString(), u" after"_s);
      QCOMPARE(field.inputMethodQuery(Qt::ImCurrentSelection).toString(), QString{});
      QCOMPARE(field.inputMethodQuery(Qt::ImTextBeforeCursor).toString(), QString{});
      QCOMPARE(field.inputMethodQuery(Qt::ImTextAfterCursor).toString(), u" after"_s);
      QCOMPARE(edited.size(), 0);
      QTRY_VERIFY_WITH_TIMEOUT(field.layout().value(u"composing"_s).toBool(), wait_ms);
      QCOMPARE(field.layout().value(u"text"_s).toString(), u"中 after"_s);
      QInputMethodEvent cancel;

      QCoreApplication::sendEvent(&field, &cancel);
      QCOMPARE(field.text(), u"before after"_s);
      QCOMPARE(field.selectedText(), u"before"_s);
      QInputMethodEvent commit;

      commit.setCommitString(u"🧵"_s);
      QCoreApplication::sendEvent(&field, &commit);
      QCOMPARE(field.text(), u"🧵 after"_s);
      QCOMPARE(edited.size(), 1);
      field.setText(u"ab after"_s);
      field.setCursorPosition(2);
      QInputMethodEvent replacement;

      replacement.setCommitString(u"X"_s, -1, 1);
      QCoreApplication::sendEvent(&field, &replacement);
      QCOMPARE(field.text(), u"aX after"_s);
      QInputMethodEvent selected{QString{}, {{QInputMethodEvent::Selection, 0, 2, {}}}};

      QCoreApplication::sendEvent(&field, &selected);
      QCOMPARE(field.selectedText(), u"aX"_s);
    }

    [[qt::slot]] static void inputContextProjectsSelectionAndProvisionalReplacement() {
      const auto text = u"a🧵b"_s;
      const auto first = static_cast<int>(u"a"_s.size());
      const auto last = static_cast<int>(u"a🧵"_s.size());
      const auto confirmed = FormInputContext::capture(text, last, first);

      QCOMPARE(confirmed.text, text);
      QCOMPARE(confirmed.cursor, last);
      QCOMPARE(confirmed.anchor, first);
      QCOMPARE(confirmed.selectedText(), u"🧵"_s);
      QCOMPARE(confirmed.beforeCursor(), u"a🧵"_s);
      QCOMPARE(confirmed.afterCursor(), u"b"_s);

      const auto backward = FormInputContext::capture(text, first, last);

      QCOMPARE(backward.selectedText(), u"🧵"_s);
      QCOMPARE(backward.beforeCursor(), u"a"_s);
      QCOMPARE(backward.afterCursor(), u"🧵b"_s);

      const auto provisional = FormInputContext::capture(text, last, first, FormInputContext::Replacement{.first = first, .last = last});

      QCOMPARE(provisional.text, u"ab"_s);
      QCOMPARE(provisional.cursor, first);
      QCOMPARE(provisional.anchor, first);
      QVERIFY(provisional.selectedText().isEmpty());
      QCOMPARE(provisional.beforeCursor(), u"a"_s);
      QCOMPARE(provisional.afterCursor(), u"b"_s);
      QCOMPARE(text, u"a🧵b"_s);
    }

    [[qt::slot]] static void cancellationAndFocusLossPreserveCommittedSelection() {
      const FieldFixture fixture;
      auto& field = fixture.field();
      const auto committed = u"before after"_s;
      const auto selected = u"before"_s;

      field.setText(committed);
      field.select(0, static_cast<int>(selected.size()));
      const QSignalSpy edited{&field, &NativeFormField::textEdited};
      QInputMethodEvent preedit{u"中"_s, {{QInputMethodEvent::Cursor, 1, 1, {}}}};

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

    [[qt::slot]] static void pasteNormalizesLinesAndBoundsUtf8Bytes() {
      auto* clipboard = QGuiApplication::clipboard();
      auto saved = copyClipboard();
      const auto restore = qScopeGuard([clipboard, saved = std::move(saved)] mutable {
        clipboard->setMimeData(saved.release());
      });

      FieldFixture fixture;
      auto& field = fixture.field();

      QVERIFY(showComponentWindow(fixture.window, wait_ms));
      constexpr int maximum_bytes = 8;

      field.setMaximumBytes(maximum_bytes);
      clipboard->setText(u"a\r\nb\rc\nd"_s);
      field.paste();
      QCOMPARE(field.text(), u"a b c d"_s);
      field.selectAll();
      clipboard->setText(u"1234567🧵"_s);
      const QSignalSpy limited{&field, &NativeFormField::limitReached};

      field.paste();
      QCOMPARE(field.text(), u"1234567"_s);
      QCOMPARE(limited.size(), 1);
      QCOMPARE(limited.front().front().toULongLong(), static_cast<qulonglong>(u"1234567🧵"_s.toUtf8().size()));
      field.setText(u"a🧵"_s);
      field.select(1, 3);
      field.copy();
      QCOMPARE(clipboard->text(), u"🧵"_s);
      field.cut();
      QCOMPARE(field.text(), u"a"_s);
    }

    [[qt::slot]] static void utf16PrefixMatchesQtEncodingAndScalarBoundaries() {
      QString text;

      for (std::uint32_t unit = 0; unit <= std::numeric_limits<char16_t>::max(); ++unit) {
        text.append(QChar{static_cast<char16_t>(unit)});
      }

      const auto high = QChar{telar::gui::Utf16Prefix::first_high_surrogate};
      const auto low = QChar{telar::gui::Utf16Prefix::first_low_surrogate};
      const telar::ds::Array samples{text, u"aé中🧵z"_s, QString{high}, QString{low}, QString{high} + low, QString{low} + high, u"a"_s + high + u"🧵z"_s, u"a"_s + low + u"🧵z"_s};
      constexpr telar::ds::Array<std::size_t, 10> capacities{0, 1, 2, 3, 4, 8, 127, 128, 256, 512};

      for (const auto& sample : samples) {
        const auto encoded = sample.toUtf8();
        const std::string_view source{encoded.constData(), static_cast<std::size_t>(encoded.size())};

        for (const auto capacity : capacities) {
          const auto fitted = telar::gui::Utf16Prefix::fit(QStringView{sample}, capacity, utf16Encoding());
          const auto expected = telar::runtime::utf8Prefix(source, capacity);
          const auto prefix = sample.first(static_cast<qsizetype>(fitted.units)).toUtf8();

          QCOMPARE(fitted.requested_bytes, static_cast<std::size_t>(encoded.size()));
          QCOMPARE(fitted.bytes, expected.size());
          QCOMPARE(prefix, QByteArray(expected.data(), static_cast<qsizetype>(expected.size())));
        }
      }
    }

    [[qt::slot]] static void pointerUsesCellMidpointsAndPreservesWholeGraphemes() {
      FieldFixture fixture;
      auto& field = fixture.field();

      QVERIFY(showComponentWindow(fixture.window, wait_ms));
      field.setText(u"a🧵b"_s);
      QVERIFY(waitForSynchronizedFrame(fixture.window, wait_ms));
      const auto content = field.layout().value(u"content"_s).toRectF();
      const auto cell = field.layout().value(u"grid"_s).toMap().value(u"cellWidth"_s).toDouble();
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
      QCOMPARE(field.selectedText(), u"🧵"_s);
    }
  };

  using telar::gui::test::QtCase;

  const QtCase<FormFieldTest, "formGeometryUsesTheBodyCellGrid"> case_form_geometry_uses_the_body_cell_grid{"form_field.form_geometry_uses_the_body_cell_grid"};
  const QtCase<FormFieldTest, "keyboardMovesAndDeletesWholeGraphemes"> case_keyboard_moves_and_deletes_whole_graphemes{"form_field.keyboard_moves_and_deletes_whole_graphemes"};
  const QtCase<FormFieldTest, "compositionKeepsCommittedTextUntilCommit"> case_composition_keeps_committed_text_until_commit{"form_field.composition_keeps_committed_text_until_commit"};
  const QtCase<FormFieldTest, "inputContextProjectsSelectionAndProvisionalReplacement"> case_input_context_projects_selection_and_provisional_replacement{"form_field.input_context_projects_selection_and_provisional_replacement"};
  const QtCase<FormFieldTest, "cancellationAndFocusLossPreserveCommittedSelection"> case_cancellation_and_focus_loss_preserve_committed_selection{"form_field.cancellation_and_focus_loss_preserve_committed_selection"};
  const QtCase<FormFieldTest, "pasteNormalizesLinesAndBoundsUtf8Bytes"> case_paste_normalizes_lines_and_bounds_utf8_bytes{"form_field.paste_normalizes_lines_and_bounds_utf8_bytes"};
  const QtCase<FormFieldTest, "utf16PrefixMatchesQtEncodingAndScalarBoundaries"> case_utf16_prefix_matches_qt_encoding_and_scalar_boundaries{"form_field.utf16_prefix_matches_qt_encoding_and_scalar_boundaries"};
  const QtCase<FormFieldTest, "pointerUsesCellMidpointsAndPreservesWholeGraphemes"> case_pointer_uses_cell_midpoints_and_preserves_whole_graphemes{"form_field.pointer_uses_cell_midpoints_and_preserves_whole_graphemes"};

}

#ifndef TELAR_MOC_RUN
#include "form_field_test.moc"
#endif