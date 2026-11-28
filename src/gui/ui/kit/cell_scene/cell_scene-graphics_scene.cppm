export module telar.gui.ui.kit.cell_scene:graphics_scene;

import std;
import telar.gui.qt;
import :window_images;
import telar.gui.foundation.terminal;
import telar.gui.application;
import telar.base.ds;
import telar.gui.foundation.core;
import telar.wire.vocabulary;

export namespace telar::gui::qt {

  // A row a scrolled or folded view draws: the screen's own row `screen_row`, or a row the
  // runtime sent apart from the screen (`screen_row` -1). `source` names where it came from and
  // `revision` its content there, so a painter knows when the row it drew is another.
  struct TerminalRow {
    std::span<const CellValue> cells;
    std::uint64_t revision = 0;
    std::uint64_t source = 0;
    std::int32_t screen_row = -1;
  };

  // Where the rows images sit on are drawn. An image's row counts from the active screen's first,
  // `live_top` rows from the top of the scrollback; a view shows the rows its folds leave from shown
  // row `top`. The rows drawn, for the images their placeholder cells show, are read where they lie:
  // a view's own rows, `view_rows`, when it has any, the screen's own otherwise. `revision` changes whenever
  // any of this does.
  struct ImageRows {
    std::uint64_t live_top = 0;
    std::uint64_t top = 0;
    const application::FoldMap<>* folds = nullptr;
    const Screen<Memory>* screen = nullptr;
    std::span<const TerminalRow> view_rows;
    std::uint64_t revision = 0;

    // A screen's own rows, as it shows them.
    [[tbc::hot_path]] [[nodiscard]] inline static tbc::val_a<ImageRows> of(tbc::ref_a<Screen<Memory>> screen) {
      const auto& scroll = screen.scroll();
      const auto rows = static_cast<std::uint64_t>(screen.rows());

      return {.live_top = scroll.total_rows > rows ? scroll.total_rows - rows : 0, .top = scroll.offset, .screen = &screen, .revision = screen.revision()};
    }

    [[tbc::hot_path]] [[nodiscard]] inline std::size_t count() const noexcept {
      if (!view_rows.empty()) {
        return view_rows.size();
      }

      return screen != nullptr ? screen->rows() : 0;
    }

    [[tbc::hot_path]] [[nodiscard]] inline std::span<const CellValue> row(std::size_t index) const noexcept {
      if (!view_rows.empty()) {
        return view_rows[index].cells;
      }

      return screen != nullptr ? screen->row(index) : std::span<const CellValue>{};
    }

    // The drawn row of `row`, counted from the top of the scrollback; nothing when a fold hides it.
    [[tbc::hot_path]] [[nodiscard]] inline ds::Option<std::int64_t> drawn(std::int64_t row) const noexcept {
      if (folds == nullptr || row < 0) {
        return row - static_cast<std::int64_t>(top);
      }

      if (folds->hides(static_cast<std::uint64_t>(row))) {
        return ds::none;
      }

      return static_cast<std::int64_t>(folds->display(static_cast<std::uint64_t>(row))) - static_cast<std::int64_t>(top);
    }
  };

  struct ImageLayers {
    QSGTransformNode* below_background;
    QSGTransformNode* below_text;
    QSGTransformNode* above_text;
  };

  class GraphicsScene {
  public:
    explicit GraphicsScene(ImageLayers layers) noexcept;
    ~GraphicsScene();
    GraphicsScene(const GraphicsScene&) = delete;
    GraphicsScene& operator=(const GraphicsScene&) = delete;
    GraphicsScene(GraphicsScene&&) = delete;
    GraphicsScene& operator=(GraphicsScene&&) = delete;
    void synchronize(QQuickItem& owner, const application::terminal::graphics::GraphicsStore<Memory>& store, const ImageRows& rows, QSizeF cell, qreal scale);
    void invalidate() noexcept;
    void clearNodes() noexcept;

  private:
    friend class WindowImages;
    static constexpr std::int32_t below_background_limit = std::numeric_limits<std::int32_t>::min() / 2;

    struct ResolvedImage {
      std::uint32_t image_id = 0;
      ds::Option<WindowImage> texture;
    };

    [[nodiscard]] std::span<const ResolvedImage> resolvedImages() const noexcept;
    [[nodiscard]] const WindowImage* texture(const application::terminal::graphics::GraphicsStore<Memory>& store, ImageKey key);
    [[nodiscard]] QSGTransformNode& layer(std::int32_t z_index) const noexcept;
    void drawPlacements(const application::terminal::graphics::GraphicsStore<Memory>& store, std::span<const GraphicsPlacement> placements, const ImageRows& rows);
    void append(QSGNode& parent, application::terminal::graphics::ImageTextureHandle handle, const application::terminal::graphics::ImageGeometry& geometry);
    void drawPlaceholder(const application::terminal::graphics::GraphicsStore<Memory>& store, const application::terminal::graphics::PlaceholderRun& run, std::uint16_t row);
    void placeholders(const application::terminal::graphics::GraphicsStore<Memory>& store, const ImageRows& rows);
    void placeholderRow(const application::terminal::graphics::GraphicsStore<Memory>& store, std::span<const CellValue> row, std::uint16_t row_index);

    ImageLayers layers_;
    QPointer<WindowImages> images_;
    QPointer<QQuickItem> owner_;
    GraphicsScene* previous_ = nullptr;
    GraphicsScene* next_ = nullptr;
    ds::Array<ResolvedImage, application::terminal::graphics::GraphicsStore<Memory>::image_capacity> resolved_;
    std::size_t resolved_count_ = 0;
    application::terminal::graphics::GraphicsLifetime graphics_lifetime_;
    std::uint64_t graphics_revision_ = 0;
    std::uint64_t placement_revision_ = 0;
    std::uint64_t rows_revision_ = 0;
    QSizeF cell_;
    Rect viewport_;
    qreal scale_ = 0;
    std::size_t draw_count_ = 0;
    bool invalidated_ = true;
    bool waiting_ = false;
    bool retry_requested_ = false;
  };

}
