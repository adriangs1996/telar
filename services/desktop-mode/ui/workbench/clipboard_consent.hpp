#pragma once

#include "clipboard_task.hpp"
#include <QPointer>
#include <QCloseEvent>
#include <QKeyEvent>
#include <QMouseEvent>
#include <QPainter>
#include <QQuickPaintedItem>
#include <QQuickWindow>
#include <QTimer>
#include <functional>
#include <array>
#include <memory>

namespace workbench {

class ClipboardConsentWindow final : public QQuickWindow {
  class Content final : public QQuickPaintedItem {
  public:
    Content(ClipboardConsentWindow &window, QString description, bool rememberable)
        : QQuickPaintedItem(window.contentItem()), window_(window), description_(std::move(description)), rememberable_(rememberable) {
      setWidth(540);
      setHeight(220);
      setAcceptedMouseButtons(Qt::LeftButton);
    }

    void paint(QPainter *painter) override {
      painter->fillRect(boundingRect(), QColor{"#20242b"});
      painter->setPen(Qt::white);
      QFont font;
      font.setPixelSize(16);
      painter->setFont(font);
      painter->drawText(QRectF{24, 20, 492, 116}, Qt::TextWordWrap, description_);
      constexpr std::array labels{"Deny", "Allow once", "Allow for session"};
      for (std::size_t index = 0; index < labels.size(); ++index) {
        const QRectF button{24.0 + index * 168.0, 156, 156, 42};
        painter->fillRect(button, QColor{index == 2 && !rememberable_ ? "#252a30" : "#394452"});
        painter->drawText(button, Qt::AlignCenter, QString::fromLatin1(labels[index]));
      }
    }

  protected:
    void mousePressEvent(QMouseEvent *event) override {
      for (unsigned index = 0; index < (rememberable_ ? 3u : 2u); ++index) {
        if (QRectF{24.0 + index * 168.0, 156, 156, 42}.contains(event->position())) {
          window_.finish(static_cast<ClipboardConsent>(index));
          event->accept();
          return;
        }
      }
      event->ignore();
    }

    void keyPressEvent(QKeyEvent *event) override {
      if (event->key() == Qt::Key_Escape) {
        window_.finish(ClipboardConsent::deny);
        event->accept();
      } else {
        event->ignore();
      }
    }

  private:
    ClipboardConsentWindow &window_;
    QString description_;
    bool rememberable_;
  };

public:
  ClipboardConsentWindow(const OwnedClipboardTask &task, QObject &context, std::function<void(ClipboardConsent)> answer)
      : context_(&context), answer_(std::move(answer)) {
    setTitle(QStringLiteral("Telar clipboard permission"));
    setColor(QColor{"#20242b"});
    setMinimumSize({540, 220});
    setMaximumSize({540, 220});
    resize(540, 220);
    QString name = QString::fromUtf8(task.name.data(), static_cast<qsizetype>(task.name.size()));
    name.removeIf([](QChar character) { return character.category() == QChar::Other_Control || character.category() == QChar::Other_Format || character == QChar::LineSeparator || character == QChar::ParagraphSeparator; });
    if (name.isEmpty()) {
      name = QStringLiteral("A program");
    }
    const auto action = task.write ? QStringLiteral("replace") : QStringLiteral("read");
    const auto description = QStringLiteral("%1 in pane %2 requests permission to %3 the %4.\nApplication names are supplied by the program.")
                                 .arg(name).arg(task.ticket.pane_id).arg(action)
                                 .arg(task.primary ? QStringLiteral("primary selection") : QStringLiteral("clipboard"));
    auto *content = new Content{*this, description, task.rememberable};
    content->forceActiveFocus();
    show();
    requestActivate();
  }

protected:
  bool event(QEvent *event) override {
    if (event->type() == QEvent::Close) {
      finish(ClipboardConsent::deny);
    }
    return QQuickWindow::event(event);
  }

private:
  void finish(ClipboardConsent consent) {
    if (finished_) {
      return;
    }
    finished_ = true;
    const auto context = context_;
    auto answer = answer_;
    hide();
    // Defer delivery so the receiver can destroy this window after the input
    // event returns. The connection owns the context and cancels it on teardown.
    if (context) {
      QTimer::singleShot(0, context.data(), [answer = std::move(answer), consent] { answer(consent); });
    }
  }

  QPointer<QObject> context_;
  std::function<void(ClipboardConsent)> answer_;
  bool finished_ = false;
};

struct DesktopClipboardOperation {
  explicit DesktopClipboardOperation(const telar::ClipboardDesktopRequest &request, std::uint64_t epoch) : task(request), epoch(epoch) {}

  OwnedClipboardTask task;
  std::uint64_t epoch;
  ClipboardConsent consent = ClipboardConsent::deny;
  bool prepared = false;
  struct DeletePrompt {
    void operator()(ClipboardConsentWindow *window) const noexcept {
      if (window != nullptr) {
        window->deleteLater();
      }
    }
  };
  using Prompt = std::unique_ptr<ClipboardConsentWindow, DeletePrompt>;
  Prompt prompt;
};

}
