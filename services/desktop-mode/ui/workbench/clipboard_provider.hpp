#pragma once

#include "clipboard_task.hpp"
#include <QClipboard>
#include <QGuiApplication>
#include <QMimeData>
#include <QPointer>
#include <QStringConverter>
#include <memory>

namespace workbench {

class QtClipboardProvider {
public:
  bool supports(bool primary) const {
    const auto *clipboard = QGuiApplication::clipboard();
    return clipboard != nullptr && (!primary || clipboard->supportsSelection());
  }

  ClipboardResult read(const OwnedClipboardTask &task) const {
    auto *clipboard = QGuiApplication::clipboard();
    bool changed = false;
    QObject observer;
    QObject::connect(clipboard, &QClipboard::changed, &observer, [&](QClipboard::Mode changed_mode) {
      changed |= changed_mode == mode(task.primary);
    }, Qt::DirectConnection);
    auto result = readData(clipboard->mimeData(mode(task.primary)), task);
    return changed ? ClipboardResult{.status = telar::ClipboardDesktopStatus::failure} : result;
  }

  // QMimeData can be supplied lazily and may disappear during a platform
  // request. Guard every subsequent dereference, and own every returned value.
  static ClipboardResult readData(const QMimeData *source, const OwnedClipboardTask &task) {
    const QPointer<const QMimeData> data{source};
    ClipboardResult result{.status = telar::ClipboardDesktopStatus::success};
    if (!data) {
      return result;
    }
    if (task.listing) {
      const auto formats = data->formats();
      if (!data) {
        return {.status = telar::ClipboardDesktopStatus::failure};
      }
      const auto count = std::min<qsizetype>(formats.size(), 16);
      for (qsizetype index = 0; index < count; ++index) {
        const auto &format = formats[index];
        if (format.isEmpty() || format.size() > 256) {
          continue;
        }
        const auto encoded = format.toUtf8();
        if (encoded.size() <= 256) {
          result.available.emplace_back(encoded.constData(), encoded.size());
        }
      }
    }
    std::size_t size = 0;
    for (const auto &mime : task.mimes) {
      if (!data) {
        return {.status = telar::ClipboardDesktopStatus::failure};
      }
      const auto format = QString::fromUtf8(mime.data(), static_cast<qsizetype>(mime.size()));
      ClipboardContent content{mime, {}};
      if (textMime(mime)) {
        const bool available = data->hasText();
        if (!data) {
          return {.status = telar::ClipboardDesktopStatus::failure};
        }
        if (!available) {
          continue;
        }
        const auto text = data->text();
        if (!data || static_cast<std::size_t>(text.size()) > telar::clipboard_content_limit - size) {
          return {.status = telar::ClipboardDesktopStatus::failure};
        }
        QStringEncoder encoder{QStringEncoder::Utf8};
        constexpr qsizetype text_chunk = 4096;
        for (qsizetype offset = 0; offset < text.size(); offset += text_chunk) {
          const QByteArray encoded = encoder(QStringView{text}.mid(offset, std::min(text_chunk, text.size() - offset)));
          if (static_cast<std::size_t>(encoded.size()) > telar::clipboard_content_limit - size) {
            return {.status = telar::ClipboardDesktopStatus::failure};
          }
          size += static_cast<std::size_t>(encoded.size());
          const auto *begin = reinterpret_cast<const telar::Byte *>(encoded.constData());
          content.data.insert(content.data.end(), begin, begin + encoded.size());
        }
      } else {
        const bool available = data->hasFormat(format);
        if (!data) {
          return {.status = telar::ClipboardDesktopStatus::failure};
        }
        if (!available) {
          continue;
        }
        const QByteArray bytes = data->data(format);
        if (!data || static_cast<std::size_t>(bytes.size()) > telar::clipboard_content_limit - size) {
          return {.status = telar::ClipboardDesktopStatus::failure};
        }
        size += static_cast<std::size_t>(bytes.size());
        const auto *begin = reinterpret_cast<const telar::Byte *>(bytes.constData());
        content.data.assign(begin, begin + bytes.size());
      }
      result.contents.push_back(std::move(content));
    }
    return result;
  }

  ClipboardResult write(const OwnedClipboardTask &task) const {
    auto data = std::make_unique<QMimeData>();
    for (const auto &content : task.contents) {
      const auto format = QString::fromUtf8(content.mime.data(), static_cast<qsizetype>(content.mime.size()));
      const QByteArray bytes{reinterpret_cast<const char *>(content.data.data()), static_cast<qsizetype>(content.data.size())};
      if (textMime(content.mime)) {
        data->setText(QString::fromUtf8(bytes));
      } else {
        data->setData(format, bytes);
      }
    }
    if (task.contents.empty()) {
      data->setText({});
    }
    QGuiApplication::clipboard()->setMimeData(data.release(), mode(task.primary));
    return {.status = telar::ClipboardDesktopStatus::success};
  }

private:
  static QClipboard::Mode mode(bool primary) noexcept {
    return primary ? QClipboard::Selection : QClipboard::Clipboard;
  }

  static bool textMime(std::string_view mime) noexcept {
    return mime == "text/plain" || mime == "text/plain;charset=utf-8" || mime == "UTF8_STRING" || mime == "STRING" || mime == "TEXT";
  }
};

}
