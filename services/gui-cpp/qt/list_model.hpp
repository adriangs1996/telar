#pragma once

#include <QAbstractListModel>
#include <QVariantMap>

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
