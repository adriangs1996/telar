#pragma once

#include "list_model.hpp"
#include <QAbstractItemModel>
#include <QList>
#include <QObject>
#include <QVariantList>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qtmetamacros.h>
#include <QtQmlIntegration/qqmlintegration.h>
#include <utility>

namespace telar::gui::qt {

class HistoryMatchModel : public QObject {
  Q_OBJECT
  QML_ELEMENT
  Q_PROPERTY(QVariantList records READ records WRITE setRecords NOTIFY recordsChanged)
  Q_PROPERTY(QAbstractItemModel *model READ model CONSTANT)

public:
  explicit HistoryMatchModel(QObject *parent = nullptr)
      : QObject(parent), model_(this) {}

  [[nodiscard]] QVariantList records() const { return records_; }
  [[nodiscard]] QAbstractItemModel *model() noexcept { return &model_; }

  void setRecords(const QVariantList &records) {
    if (records_ == records) {
      return;
    }

    QList<QVariantMap> rows;
    rows.reserve(records.size());
    for (const auto &record : records) {
      rows.append(record.toMap());
    }

    records_ = records;
    model_.replaceRows(std::move(rows));
    emit recordsChanged();
  }

signals:
  void recordsChanged();

private:
  QVariantList records_;
  ListModel model_;
};

}
