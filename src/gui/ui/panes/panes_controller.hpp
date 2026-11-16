#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/app/list_model.hpp"
#include "ui/components/element_slots.hpp"
#include "ui/store/store.hpp"
#include <QAbstractItemModel>
#include <QObject>
#include <QVariantList>
#include <QtQml/qqmlregistration.h>
#include <cstdint>
#include <optional>

#pragma once

import telar.gui.model.records;

namespace telar::gui::qt {

  // The panes of the active tab, laid out in the workbench, with their headers and what a mod
  // draws in them, and the dividers between them.
  //
  // It reads the active session in the store. Each synchronize() compares what it projected last
  // with the current inputs and rebuilds the records only when one moved. The viewport revision
  // covers the workbench geometry and the rows an attachment shelf reserves under a pane.
  class PanesController final : public QObject {
    Q_OBJECT
    QML_NAMED_ELEMENT(PanesController)
    QML_UNCREATABLE("Use the window's panes")
    Q_PROPERTY(QAbstractItemModel* rows READ rows CONSTANT)
    Q_PROPERTY(QAbstractItemModel* dividers READ dividers CONSTANT)

  public:
    PanesController(Store& store, ElementSlots& elements, QObject* parent = nullptr);
    ~PanesController() override = default;
    PanesController(const PanesController&) = delete;
    PanesController& operator=(const PanesController&) = delete;
    PanesController(PanesController&&) = delete;
    PanesController& operator=(PanesController&&) = delete;

    void synchronize();
    // The active session is about to change: nothing projected belongs to the next one.
    void forget();
    // Device pixels per logical pixel of the terminal grid the records are measured in.
    void setScale(double scale) noexcept;
    [[nodiscard]] QAbstractItemModel* rows() noexcept;
    [[nodiscard]] QAbstractItemModel* dividers() noexcept;
    // How many synchronize() calls rebuilt the records, for tests and probes that check what a
    // change costs.
    [[nodiscard]] std::uint64_t rebuilds() const noexcept;

  private:
    struct Inputs {
      std::uint64_t machine_view = 0;
      std::uint64_t runtime_generation = 0;
      std::uint64_t active_tab = 0;
      std::uint64_t panes = 0;
      std::uint64_t host = 0;
      std::uint64_t configuration = 0;
      std::uint64_t chrome = 0;
      std::uint64_t agents = 0;
      std::uint64_t graphics = 0;
      std::uint64_t elements = 0;
      std::uint64_t viewport = 0;
      double scale = 1;

      bool operator==(const Inputs&) const = default;
    };

    [[nodiscard]] Inputs inputs() const;
    [[nodiscard]] QVariantList fullscreenEntries(const Tab<Memory>& tab) const;

    Store& store_;
    ElementSlots& elements_;
    ListModel rows_;
    ListModel dividers_;
    double scale_ = 1;
    std::optional<Inputs> synchronized_;
    std::uint64_t rebuilds_ = 0;
  };

}
