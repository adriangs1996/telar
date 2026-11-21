#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "nvim_item.hpp"
#include <QList>
#include <QPointer>
#include <QQuickItem>
#include <QtQml/qqmlregistration.h>
#include <cstdint>

#pragma once

import telar.gui.foundation.core;
import telar.gui.application;
import telar.base.ds;

namespace telar::gui::qt {

  // The cells of one grid of an editor, drawn as a terminal's rows are: QML places one over
  // each grid the editor has, and frames the floats.
  class NvimGridItem : public QQuickItem {
    Q_OBJECT
    QML_NAMED_ELEMENT(NvimGrid)
    Q_PROPERTY(telar::gui::qt::NvimItem* editor READ editor WRITE setEditor NOTIFY editorChanged)
    Q_PROPERTY(int gridId READ gridId WRITE setGridId NOTIFY gridIdChanged)

  public:
    explicit NvimGridItem(QQuickItem* parent = nullptr);

    [[nodiscard]] NvimItem* editor() const noexcept {
      return editor_;
    }

    void setEditor(NvimItem* editor);

    [[nodiscard]] int gridId() const noexcept {
      return static_cast<int>(grid_id_);
    }

    void setGridId(int grid_id);

  signals:
    void editorChanged();
    void gridIdChanged();

  protected:
    void updatePolish() override;
    QSGNode* updatePaintNode(QSGNode* previous, UpdatePaintNodeData* data) override;

  private:
    [[nodiscard]] const application::nvim::Grid* grid() const noexcept;
    void refresh();

    QPointer<NvimItem> editor_;
    std::uint32_t grid_id_ = 0;

    // What the item last drew: its screen's revision, how cells are drawn, and whether the
    // cursor was lit and the editor had the keyboard. A frame that changes none of them leaves
    // the item as it is.
    struct Drawn {
      std::uint64_t revision = 0;
      std::uint64_t appearance = 0;
      bool cursor_on = false;
      bool keyboard = false;

      bool operator==(const Drawn&) const = default;
    };

    ds::Option<Drawn> drawn_;
    // The revision of each row when its fonts were last asked for.
    QList<std::uint64_t> font_row_revisions_;
    std::uint64_t font_appearance_ = 0;
  };

}
