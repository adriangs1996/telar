#pragma once

#include "ui/workbench/terminal_screen.hpp"
#include <QCoreApplication>
#include <QJsonObject>
#include <QThread>
#include <chrono>

namespace desktop_test {

using workbench::TerminalScreen;

inline void require(bool condition, std::string_view message) {
  if (!condition) {
    throw std::runtime_error{std::string{message}};
  }
}

template <typename Condition>
void await(Condition condition, std::string_view stage) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{15};
  while (!condition()) {
    if (std::chrono::steady_clock::now() >= deadline) {
      throw std::runtime_error{"Timed out: " + std::string{stage}};
    }

    QCoreApplication::processEvents(QEventLoop::AllEvents, 5);
    QThread::msleep(1);
  }
}

inline QByteArray text(const TerminalScreen &screen) {
  QByteArray result;
  for (std::size_t index = 0; index < screen.cells.size(); ++index) {
    const auto &cell = screen.cells[index];
    result.append(cell.text.data(), cell.length);
    if ((index + 1) % screen.columns == 0) {
      result.append('\n');
    }
  }

  return result;
}

inline QJsonObject snapshot(const TerminalScreen &screen) {
  std::vector<telar::Cell> cells;
  for (const auto &cell : screen.cells) {
    cells.push_back({cell.width, cell.style, {reinterpret_cast<const telar::Byte *>(cell.text.data()), cell.length}});
  }

  std::vector<telar::Byte> buffer(telar::CellRunCodec::encodedSize(cells));
  const auto encoded = telar::CellRunCodec::encode(cells, buffer);
  const QByteArray bytes{reinterpret_cast<const char *>(encoded.data()), static_cast<qsizetype>(encoded.size())};
  return {{"columns", screen.columns}, {"rows", screen.rows}, {"cells", QString::fromLatin1(bytes.toBase64())}, {"cursor_x", screen.cursor.x}, {"cursor_y", screen.cursor.y}, {"scroll_offset", static_cast<qint64>(screen.scroll.offset)}, {"scroll_rows", static_cast<qint64>(screen.scroll.total_rows)}};
}

}
