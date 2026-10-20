#pragma once

#include <QPointer>
#include <QString>
#include <QVariantMap>
#include <functional>
#include <memory>

struct QuickSurface;
class QQuickItem;

namespace ui {
  struct SurfaceEvent {
    QString name;
    QPointer<QQuickItem> target;
    QPointer<QQuickItem> current_target;
    QVariantMap data;
  };

  struct EventReply {
    bool accepted = false;
    bool stopped = false;
    bool capture = false;
    bool release_capture = false;
    bool focus = false;
    Qt::DropAction drop_action = Qt::IgnoreAction;
  };

  class SurfaceEvents final {
  public:
    using Callback = std::function<EventReply(const SurfaceEvent &)>;

    SurfaceEvents(QuickSurface &surface, QQuickItem &root);
    ~SurfaceEvents();

    quint64 subscribe(QQuickItem *item, const QString &name, Callback callback);
    void unsubscribe(quint64 identifier);
    void registerShape(QQuickItem *item);
    void focus(QQuickItem *item);
    void setInputMethod(QQuickItem *item, const QVariantMap &options);
    QVariantMap state() const;
    void activate();
    void deactivate();

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
  };
} // namespace ui
