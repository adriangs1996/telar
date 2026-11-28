export module telar.gui.ui.app.panes.terminal.history.layout:history_row_layout;

import std;
import telar.gui.qt;
import telar.gui.foundation.core;
import telar.gui.foundation.forms;
import telar.gui.application;
import telar.base.ds;
import telar.shell.syntax;
import telar.base.memory.allocators;

export namespace telar::gui::qt {

  class [[qt::object, qt::qml_element]] HistoryRowLayout : public QQuickItem {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    enum class Index : std::int8_t {
      missing = -1,
    };

    explicit HistoryRowLayout(QQuickItem* parent = nullptr);
    [[nodiscard]] QVariantMap measurements() const;
    void setMeasurements(const QVariantMap& measurements);
    [[nodiscard]] QVariantMap layout() const;
    [[nodiscard]] QVariantMap geometryLayout() const;

    [[tbc::hot_path]] [[nodiscard]] inline QVariantList ranges() const {
      return ranges_;
    }

    void setRanges(const QVariantList& ranges);
    [[nodiscard]] Rect physicalFrame() const noexcept;

    [[tbc::hot_path]] [[nodiscard]] inline int historyIndex() const noexcept {
      return history_index_;
    }

    void setHistoryIndex(int index);

    [[qt::signal]] void historyIndexChanged();
    [[qt::signal]] void measurementsChanged();
    [[qt::signal]] void layoutChanged();
    [[qt::signal]] void geometryLayoutChanged();
    [[qt::signal]] void lineLayoutChanged();
    [[qt::signal]] void rangesChanged();

  protected:
    void updatePolish() override;
    void componentComplete() override;
    void geometryChange(const QRectF& current, const QRectF& previous) override;
    void itemChange(ItemChange change, const ItemChangeData& data) override;

  private:
    struct GeometryState {
      application::history::HistoryRowGeometry row;
      qreal density = 1;
      qreal ratio = 1;
      float card_height = 0;
      Rect meta;
      std::uint16_t more = 0;

      [[tbc::hot_path]] inline bool operator==(const GeometryState& other) const {
        return row == other.row && std::equal_to<>{}(density, other.density) && std::equal_to<>{}(ratio, other.ratio) && std::equal_to<>{}(card_height, other.card_height) && meta == other.meta && more == other.more;
      }
    };

    [[nodiscard]] GeometryState geometryState() const noexcept;
    [[nodiscard]] QRectF logical(Rect area) const noexcept;
    [[nodiscard]] QVariantList commandLines() const;
    [[nodiscard]] QVariantMap commandLine(std::string_view text, std::size_t offset, Rect bounds, bool continues, HistoryMatchHighlight& highlight) const;
    void prepareCommand();
    // What the runtime matched in the command, read once per command and ranges.
    void prepareMatches();
    // How the shell reads the command, once the card shows it whole.
    void prepareStyles();
    // The runs of line `text`, at byte `offset` of the command, in the shell's colours.
    [[nodiscard]] QVariantList styledRuns(std::string_view text, std::size_t offset, Rect bounds) const;
    void publishLines();

    QVariantMap measurements_;
    QString command_text_;
    QVariantList ranges_;
    QByteArray command_bytes_;
    HistoryMatchRanges matches_;
    // QML makes the item, so it owns the memory its buffers live in.
    SystemAllocator memory_;
    MemoryAdapter<SystemAllocator> adapter_{memory_};
    ds::Vec<application::prompt::Style, Memory> styles_{adapter_};
    ds::Vec<shell::Token, Memory> tokens_{adapter_};
    bool styled_ = false;
    application::history::HistoryRowGeometry geometry_;
    application::history::HistoryCard card_;
    qreal density_ = 1;
    qreal ratio_ = 1;
    float command_width_ = 0;
    float cell_width_ = 1;
    float cell_height_ = 1;
    std::uint32_t first_line_columns_ = 0;
    int history_index_ = static_cast<int>(Index::missing);
    bool measurements_dirty_ = true;
    bool query_dirty_ = false;
    bool expanded_ = false;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("measurements", &HistoryRowLayout::measurements).withWrite(&HistoryRowLayout::setMeasurements).withNotify(&HistoryRowLayout::measurementsChanged),
        telar::qt::property("layout", &HistoryRowLayout::layout).withNotify(&HistoryRowLayout::layoutChanged),
        telar::qt::property("geometryLayout", &HistoryRowLayout::geometryLayout).withNotify(&HistoryRowLayout::geometryLayoutChanged),
        telar::qt::property("lineLayout", &HistoryRowLayout::commandLines).withNotify(&HistoryRowLayout::lineLayoutChanged),
        telar::qt::property("ranges", &HistoryRowLayout::ranges).withWrite(&HistoryRowLayout::setRanges).withNotify(&HistoryRowLayout::rangesChanged),
        telar::qt::property("historyIndex", &HistoryRowLayout::historyIndex).withWrite(&HistoryRowLayout::setHistoryIndex).withNotify(&HistoryRowLayout::historyIndexChanged)
    );
  };

}
