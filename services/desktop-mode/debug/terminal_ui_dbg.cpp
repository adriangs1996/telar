// Checks the terminal's appearance end to end: font settings and their errors, ligature spacing,
// optical text strength where the platform draws it, translucent backgrounds, and that editing
// one row leaves the others untouched. It exits nonzero on any failed check; --images DIR also
// saves the frames it compared.

#include "ui/workbench/optical_text.hpp"
#include "ui/workbench/terminal_font.hpp"
#include "ui/workbench/terminal_item.hpp"
#include <QCommandLineParser>
#include <QDir>
#include <QFontInfo>
#include <QEventLoop>
#include <QGuiApplication>
#include <QImage>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QQuickWindow>
#include <QTextLayout>
#include <QTimer>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <stdexcept>

namespace {
  constexpr int columns = 36, rows = 7;
  int failures = 0;

  // Reports a failed expectation and counts it; an assert would vanish from a release build.
  void check(bool passed, const char *expectation) {
    if (!passed) {
      std::fprintf(stderr, "FAIL: %s\n", expectation);
      ++failures;
    }
  }

  QImage frame(QQuickWindow &window) {
    QEventLoop loop;
    QTimer::singleShot(50, &loop, &QEventLoop::quit);
    loop.exec();
    auto image = window.grabWindow();
    check(!image.isNull(), "the window can be captured");
    return image;
  }

  QVariantMap appearance(QVariantMap font, double opacity) {
    return {{"theme",
             QVariantMap{{"terminal",
                          QVariantMap{{"foreground", "#ffffff"},
                                      {"background", "#211b2f"},
                                      {"selection", "#433661"},
                                      {"background_opacity", opacity},
                                      {"font", font},
                                      {"ansi", QVariantMap{{"red", "#ff0000"}}}}}}}};
  }

  void fails(const QVariantMap &settings) {
    bool rejected = false;

    try {
      workbench::TerminalFont::resolve(settings, 1);
    } catch (const std::runtime_error &) {
      rejected = true;
    }

    check(rejected, "invalid font settings are rejected");
  }
} // namespace

int main(int argc, char **argv) {
  QGuiApplication application(argc, argv);
  QCommandLineParser parser;
  parser.addHelpOption();
  const QCommandLineOption images_option(
      "images", "Save the compared frames as PNG files in this existing directory.", "directory");
  parser.addOption(images_option);
  parser.process(application);
  const auto images = parser.value(images_option);
  QVariantMap font{{"size", 20}, {"line_height", 1.2}, {"letter_spacing", 1.0}};
  const auto plain = workbench::TerminalFont::resolve(font, 1);
  font.insert("thicken", true);
  font.insert("thicken_strength", 128);
  const auto thickened = workbench::TerminalFont::resolve(font, 1);
  check(plain.cell == thickened.cell && plain.baseline == thickened.baseline,
        "thickening keeps the cell and baseline");
  const auto named = workbench::TerminalFont::resolve({{"style", "rEgUlAr"}}, 1);

  for (const auto &face : named.faces) {
    check(face.styleName().compare("Regular", Qt::CaseInsensitive) == 0,
          "a style matches case-insensitively in every face");
  }

  fails({{"family", "Telar non-existent font family"}});
  fails({{"style", "Telar non-existent font style"}});
  fails({{"size", 6}, {"letter_spacing", -5}});

  for (const auto &face : plain.faces) {
    QTextLayout layout("-> != ==", face);
    layout.beginLayout();
    auto line = layout.createLine();
    line.setNumColumns(layout.text().size());
    layout.endLayout();
    check(std::abs(line.horizontalAdvance() - layout.text().size() * plain.cell.width()) < 0.1,
          "ligatures keep one cell per character");
    check(face.featureValue("liga") == 1 && face.featureValue("calt") == 1,
          "every face keeps programming ligatures");
  }

  auto screen = std::make_shared<workbench::TerminalScreen>();
  screen->columns = columns;
  screen->rows = rows;
  screen->connected = true;
  screen->cursor.visible = false;
  screen->cells.resize(columns * rows);
  screen->revisions.resize(rows, 1);

  for (auto &cell : screen->cells) {
    cell.text[0] = ' ';
    cell.length = 1;
  }

  const auto sample = QByteArray("Optical -> != == fi fl st 0123");

  for (qsizetype index = 0; index < sample.size(); ++index) {
    for (int style = 0; style < 4; ++style) {
      auto &cell = screen->cells[style * columns + index];
      cell.text[0] = sample[index];
      cell.style.flags = style;
    }
  }

  const auto grapheme = [&](int column, QByteArray bytes) {
    auto &cell = screen->cells[columns * 4 + column];
    std::copy(bytes.begin(), bytes.end(), cell.text.begin());
    cell.length = static_cast<std::uint8_t>(bytes.size());
  };
  grapheme(0, QByteArray::fromHex("65cc81"));
  grapheme(2, QByteArray::fromHex("ee82a0"));
  grapheme(4, QByteArray::fromHex("e697a5"));
  screen->cells[columns * 4 + 4].width = telar::CellWidth::wide;
  screen->cells[columns * 4 + 5].width = telar::CellWidth::continuation;
  screen->cells[columns * 5].style.background = {telar::CellColor::Kind::indexed, {1, 0, 0}};
  QQmlEngine engine;
  QQmlComponent component(&engine);
  component.setData("import QtQuick; Rectangle { color: '#80211b2f' }", QUrl());
  QQuickWindow window;
  window.setColor(Qt::transparent);
  auto *background = qobject_cast<QQuickItem *>(component.create());
  check(background, "the pane background loads");
  background->setParentItem(window.contentItem());
  workbench::TerminalItem terminal(screen, window.contentItem());
  terminal.setZ(1);
  font.insert("thicken", false);
  terminal.configure(appearance(font, 0.5));
  const auto cell = terminal.cellSize();
  terminal.setSize({cell.width() * columns, cell.height() * rows});
  background->setSize(terminal.size());
  window.resize(qCeil(terminal.width()), qCeil(terminal.height()));
  window.show();
  auto regular = frame(window);
  const auto scale = window.devicePixelRatio();
  const auto blank =
      regular.pixelColor(qRound(cell.width() * 10 * scale), qRound(cell.height() * 6.5 * scale));
  check(std::abs(blank.alpha() - 128) <= 1, "a translucent pane shows its background once");
  const auto explicit_bg =
      regular.pixelColor(qRound(cell.width() / 2 * scale), qRound(cell.height() * 5.5 * scale));
  check(explicit_bg == QColor(Qt::red), "a cell background keeps its own color");

  font.insert("thicken", true);
  font.insert("thicken_strength", 0);
  terminal.configure(appearance(font, 0.5));
  auto light = frame(window);
  font.insert("thicken_strength", 255);
  terminal.configure(appearance(font, 0.5));
  auto strong = frame(window);
  check(terminal.cellSize() == cell, "thickening keeps the cell size");
  check(frame(window) == strong, "an unchanged screen draws the same frame");
  // Where the platform has no optical text, strength changes nothing.
  const bool optical = workbench::OpticalText::create() != nullptr;
  check(optical ? light != strong : light == strong, "thicken strength changes optical weight");

  screen->cells[columns].text[0] = 'X';
  ++screen->revisions[1];
  terminal.refresh();
  const auto edited = frame(window);
  check(edited != strong, "an edited row draws again");
  check(edited.copy(0, 0, edited.width(), qFloor(cell.height() * scale)) ==
            strong.copy(0, 0, strong.width(), qFloor(cell.height() * scale)),
        "editing one row leaves the row above untouched");

  terminal.configure(appearance(font, 1));
  auto opaque = frame(window);
  check(opaque.pixelColor(qRound(cell.width() * 10 * scale),
                          qRound(cell.height() * 6.5 * scale)) == QColor("#211b2f"),
        "an opaque pane paints the terminal background");

  if (!images.isEmpty()) {
    const QDir directory(images);
    regular.save(directory.filePath("terminal-regular.png"));
    light.save(directory.filePath("terminal-thicken-0.png"));
    strong.save(directory.filePath("terminal-thicken-255.png"));
  }

  if (failures != 0) {
    std::fprintf(stderr, "Terminal UI: %d checks failed\n", failures);
    return 1;
  }

  std::puts("Terminal UI: font settings, ligature spacing, optical strength and background opacity "
            "passed");
  return 0;
}
