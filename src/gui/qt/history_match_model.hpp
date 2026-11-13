#pragma once

#include "list_model.hpp"
#include <QAbstractItemModel>
#include <QList>
#include <QObject>
#include <QVariantList>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <QtQmlIntegration/qqmlintegration.h>
#include <algorithm>
#include <utility>

namespace telar::gui::qt {

class HistoryMatchModel : public QObject {
  Q_OBJECT
  QML_ELEMENT
  Q_PROPERTY(QVariantList records READ records WRITE setRecords NOTIFY recordsChanged)
  Q_PROPERTY(QAbstractItemModel *model READ model CONSTANT)
  Q_PROPERTY(int activeCount READ activeCount NOTIFY recordsChanged)

public:
  explicit HistoryMatchModel(QObject *parent = nullptr)
      : QObject(parent), model_(this) {}

  [[nodiscard]] QVariantList records() const { return records_; }
  [[nodiscard]] QAbstractItemModel *model() noexcept { return &model_; }
  [[nodiscard]] int activeCount() const noexcept { return static_cast<int>(records_.size()); }

  void setRecords(const QVariantList &records) {
    if (records_ == records) {
      return;
    }

    QList<QVariantMap> rows;
    const auto retained = std::min(model_.rowCount(), maximum_retained_matches);
    rows.reserve(std::max(records.size(), static_cast<qsizetype>(retained)));
    for (const auto &record : records) {
      rows.append(record.toMap());
    }

    for (auto index = records.size(); index < retained; ++index) {
      rows.append(model_.data(model_.index(static_cast<int>(index)), ListModel::record_role).toMap());
    }

    records_ = records;
    model_.replaceRows(std::move(rows));
    emit recordsChanged();
  }

signals:
  void recordsChanged();

private:
  static constexpr int maximum_retained_matches = 8;
  QVariantList records_;
  ListModel model_;
};

}
