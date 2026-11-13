#pragma once

#include <QAbstractListModel>
#include <QVariantMap>
#include <algorithm>

namespace telar::gui::qt {

class ListModel final : public QAbstractListModel {
public:
  static constexpr int record_role = Qt::UserRole + 1;

  explicit ListModel(QObject *parent = nullptr)
      : QAbstractListModel(parent) {}

  [[nodiscard]] int rowCount(const QModelIndex &parent = {}) const override {
    return parent.isValid() ? 0 : static_cast<int>(rows_.size());
  }

  [[nodiscard]] QVariant data(const QModelIndex &index, int role) const override {
    if (role != record_role || !index.isValid() || index.row() < 0 || index.row() >= rows_.size()) {
      return {};
    }

    return rows_[index.row()];
  }

  [[nodiscard]] QHash<int, QByteArray> roleNames() const override {
    return {{record_role, "record"}};
  }

  // Snapshot consumers identify rows by position and validate actions with record keys or revisions.
  void replaceRows(QList<QVariantMap> incoming) {
    const auto shared = std::min(rows_.size(), incoming.size());
    auto first_changed = shared;
    qsizetype last_changed = 0;
    for (qsizetype index = 0; index < shared; ++index) {
      if (rows_[index] != incoming[index]) {
        rows_[index] = std::move(incoming[index]);
        first_changed = std::min(first_changed, index);
        last_changed = index;
      }
    }

    if (first_changed != shared) {
      emit dataChanged(index(static_cast<int>(first_changed)), index(static_cast<int>(last_changed)), {record_role});
    }

    if (rows_.size() > incoming.size()) {
      beginRemoveRows({}, static_cast<int>(incoming.size()), static_cast<int>(rows_.size() - 1));
      rows_.erase(rows_.begin() + incoming.size(), rows_.end());
      endRemoveRows();
    } else if (rows_.size() < incoming.size()) {
      beginInsertRows({}, static_cast<int>(rows_.size()), static_cast<int>(incoming.size() - 1));
      rows_.reserve(incoming.size());
      for (auto index = shared; index < incoming.size(); ++index) {
        rows_.append(std::move(incoming[index]));
      }

      endInsertRows();
    }
  }

  void reconcile(QList<QVariantMap> incoming) {
    for (qsizetype index = 0; index < incoming.size(); ++index) {
      const auto key = incoming[index].value(QStringLiteral("key"));
      auto found = index;
      while (found < rows_.size() && rows_[found].value(QStringLiteral("key")) != key) {
        ++found;
      }

      if (found == rows_.size()) {
        beginInsertRows({}, static_cast<int>(index), static_cast<int>(index));
        rows_.insert(index, incoming[index]);
        endInsertRows();
      } else if (found != index) {
        beginMoveRows({}, static_cast<int>(found), static_cast<int>(found), {}, static_cast<int>(index));
        rows_.move(found, index);
        endMoveRows();
      }

      if (rows_[index] != incoming[index]) {
        rows_[index] = std::move(incoming[index]);
        emit dataChanged(this->index(static_cast<int>(index)), this->index(static_cast<int>(index)), {record_role});
      }
    }

    if (rows_.size() > incoming.size()) {
      beginRemoveRows({}, static_cast<int>(incoming.size()), static_cast<int>(rows_.size() - 1));
      rows_.erase(rows_.begin() + incoming.size(), rows_.end());
      endRemoveRows();
    }
  }

private:
  QList<QVariantMap> rows_;
};

}
