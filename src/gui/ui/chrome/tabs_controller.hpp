#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/app/list_model.hpp"
#include "ui/components/element_slots.hpp"
#include "ui/store/store.hpp"
#include <QAbstractItemModel>
#include <QObject>
#include <QtQml/qqmlregistration.h>
#include <cstdint>
#include <optional>

#pragma once

namespace telar::gui::qt {

  // The tabs of the active workspace, in their order, with what a mod draws for each.
  //
  // It reads the active session in the store. Each synchronize() compares the versions it
  // projected last with the current ones and rebuilds the records only when one moved.
  class TabsController final : public QObject {
    Q_OBJECT
    QML_NAMED_ELEMENT(TabsController)
    QML_UNCREATABLE("Use the window's tabs")
    Q_PROPERTY(QAbstractItemModel* rows READ rows CONSTANT)

  public:
    TabsController(Store& store, ElementSlots& elements, QObject* parent = nullptr);
    ~TabsController() override = default;
    TabsController(const TabsController&) = delete;
    TabsController& operator=(const TabsController&) = delete;
    TabsController(TabsController&&) = delete;
    TabsController& operator=(TabsController&&) = delete;

    void synchronize();
    // The active session is about to change: nothing projected belongs to the next one.
    void forget();
    [[nodiscard]] QAbstractItemModel* rows() noexcept;
    [[nodiscard]] int count() const noexcept;
    // How many synchronize() calls rebuilt the records, for tests and probes that check what a
    // change costs.
    [[nodiscard]] std::uint64_t rebuilds() const noexcept;

  private:
    struct Inputs {
      std::uint64_t machine_view = 0;
      std::uint64_t runtime_generation = 0;
      std::uint64_t tabs = 0;
      std::uint64_t active_tab = 0;
      std::uint64_t panes = 0;
      std::uint64_t configuration = 0;
      std::uint64_t chrome = 0;
      std::uint64_t agents = 0;
      std::uint64_t elements = 0;

      bool operator==(const Inputs&) const = default;
    };

    [[nodiscard]] Inputs inputs() const;

    Store& store_;
    ElementSlots& elements_;
    ListModel rows_;
    std::optional<Inputs> synchronized_;
    std::uint64_t rebuilds_ = 0;
  };

}
