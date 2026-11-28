export module telar.gui.ui.kit.models:list_model;

import std;
import telar.gui.qt;

export namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  class ListModel final : public QAbstractListModel {
  public:
    static constexpr int record_role = Qt::UserRole + 1;

    [[tbc::hot_path]] inline explicit ListModel(QObject* parent = nullptr)
        : QAbstractListModel(parent) {}

    ~ListModel() override;

    ListModel(const ListModel&) = delete;
    ListModel& operator=(const ListModel&) = delete;
    ListModel(ListModel&&) = delete;
    ListModel& operator=(ListModel&&) = delete;

    [[tbc::hot_path]] [[nodiscard]] inline int rowCount(const QModelIndex& parent = {}) const override {
      return parent.isValid() ? 0 : static_cast<int>(rows_.size());
    }

    [[tbc::hot_path]] [[nodiscard]] inline QVariant data(const QModelIndex& index, int role) const override {
      if (role != record_role || !index.isValid() || index.row() < 0 || index.row() >= rows_.size()) {
        return {};
      }

      return rows_[index.row()];
    }

    [[tbc::hot_path]] [[nodiscard]] inline QHash<int, QByteArray> roleNames() const override {
      return {{record_role, "record"}};
    }

    // Snapshot consumers identify rows by position and validate actions with record keys or revisions.
    [[tbc::hot_path]] inline void replaceRows(QList<QVariantMap> incoming) {
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
        dataChanged(index(static_cast<int>(first_changed)), index(static_cast<int>(last_changed)), {record_role});
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

    [[tbc::hot_path]] inline void reconcile(QList<QVariantMap> incoming) {
      for (qsizetype index = 0; index < incoming.size(); ++index) {
        const auto key = incoming[index].value(u"key"_s);
        auto found = index;

        while (found < rows_.size() && rows_[found].value(u"key"_s) != key) {
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
          dataChanged(this->index(static_cast<int>(index)), this->index(static_cast<int>(index)), {record_role});
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
