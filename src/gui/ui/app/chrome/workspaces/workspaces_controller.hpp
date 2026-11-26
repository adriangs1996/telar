#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/kit/models/list_model.hpp"
#include "ui/kit/store/store.hpp"
#include <QAbstractItemModel>
#include <QObject>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>
#include <cstdint>
#include <optional>

#pragma once

import telar.base.ds;

namespace telar::gui::qt {

  // The projects the navigation bar lists, and the workspace the active tab belongs to.
  //
  // It reads the active session in the store. Each synchronize() compares the versions it
  // projected last with the current ones and rebuilds the records only when one moved.
  class WorkspacesController final : public QObject {
    Q_OBJECT
    QML_NAMED_ELEMENT(WorkspacesController)
    QML_UNCREATABLE("Use the window's workspaces")
    Q_PROPERTY(QAbstractItemModel* rows READ rows CONSTANT)
    Q_PROPERTY(QVariantMap context READ context NOTIFY contextChanged)

  public:
    explicit WorkspacesController(Store& store, QObject* parent = nullptr);
    ~WorkspacesController() override = default;
    WorkspacesController(const WorkspacesController&) = delete;
    WorkspacesController& operator=(const WorkspacesController&) = delete;
    WorkspacesController(WorkspacesController&&) = delete;
    WorkspacesController& operator=(WorkspacesController&&) = delete;

    void synchronize();
    // The active session is about to change: nothing projected belongs to the next one.
    void forget();
    [[nodiscard]] QAbstractItemModel* rows() noexcept;
    [[nodiscard]] int count() const noexcept;
    [[nodiscard]] const QVariantMap& context() const noexcept;
    // How many synchronize() calls rebuilt the records, for tests and probes that check what a
    // change costs.
    [[nodiscard]] std::uint64_t rebuilds() const noexcept;

  signals:
    void contextChanged();

  private:
    struct Inputs {
      std::uint64_t machine_view = 0;
      std::uint64_t runtime_generation = 0;
      std::uint64_t workspace = 0;
      std::uint64_t active_tab = 0;
      std::uint64_t workspace_list = 0;
      std::uint64_t agents = 0;

      bool operator==(const Inputs&) const = default;
    };

    [[nodiscard]] Inputs inputs() const;

    Store& store_;
    ListModel rows_;
    QVariantMap context_;
    ds::Option<Inputs> synchronized_;
    std::uint64_t rebuilds_ = 0;
  };

}
