#pragma once

#include <QImage>
#include <QQuickItem>
#include <QSGNode>
#include <QtQml/qqmlregistration.h>

namespace telar::gui::qt {

class AttachmentImage : public QQuickItem {
  Q_OBJECT
  QML_ELEMENT
  Q_PROPERTY(QImage image READ image WRITE setImage NOTIFY imageChanged)
  Q_PROPERTY(bool thumbnail READ thumbnail WRITE setThumbnail NOTIFY imageChanged)

public:
  explicit AttachmentImage(QQuickItem *parent = nullptr);
  [[nodiscard]] QImage image() const;
  void setImage(QImage image);
  [[nodiscard]] bool thumbnail() const noexcept;
  void setThumbnail(bool thumbnail);

signals:
  void imageChanged();

protected:
  QSGNode *updatePaintNode(QSGNode *previous, UpdatePaintNodeData *data) override;

private:
  QImage image_;
  bool thumbnail_ = false;
};

}
