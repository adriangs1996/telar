export module telar.gui.ui.app.panes.terminal.history:history_match_model;

import std;
import telar.gui.qt;
import telar.gui.ui.kit.models;

export namespace telar::gui::qt {

  class [[qt::object, qt::qml_element]] HistoryMatchModel : public QObject {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    [[tbc::hot_path]] inline explicit HistoryMatchModel(QObject* parent = nullptr)
        : QObject(parent),
          model_(this) {}

    [[tbc::hot_path]] [[nodiscard]] inline QVariantList records() const {
      return records_;
    }

    [[tbc::hot_path]] [[nodiscard]] inline QAbstractItemModel* model() noexcept {
      return &model_;
    }

    [[tbc::hot_path]] [[nodiscard]] inline int activeCount() const noexcept {
      return static_cast<int>(records_.size());
    }

    [[tbc::hot_path]] inline void setRecords(const QVariantList& records) {
      if (records_ == records) {
        return;
      }

      QList<QVariantMap> rows;
      const auto retained = std::min(model_.rowCount(), maximum_retained_matches);

      rows.reserve(std::max(records.size(), static_cast<qsizetype>(retained)));
      for (const auto& record : records) {
        rows.append(record.toMap());
      }

      for (auto index = records.size(); index < retained; ++index) {
        rows.append(model_.data(model_.index(static_cast<int>(index)), ListModel::record_role).toMap());
      }

      records_ = records;
      model_.replaceRows(std::move(rows));
      recordsChanged();
    }

    [[qt::signal]] void recordsChanged();

  private:
    static constexpr int maximum_retained_matches = 8;
    QVariantList records_;
    ListModel model_;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("records", &HistoryMatchModel::records).withWrite(&HistoryMatchModel::setRecords).withNotify(&HistoryMatchModel::recordsChanged),
        telar::qt::property("model", &HistoryMatchModel::model).constant(),
        telar::qt::property("activeCount", &HistoryMatchModel::activeCount).withNotify(&HistoryMatchModel::recordsChanged)
    );
  };

}
