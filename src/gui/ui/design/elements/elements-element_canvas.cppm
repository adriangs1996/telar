export module telar.gui.ui.design.elements:element_canvas;

import std;
import telar.gui.qt;

export namespace telar::gui::qt {

  // Draws a mod's vector operations. The list arrives already validated and with its colours
  // resolved; the item repaints only when the list or its size changes, never per frame.
  class [[qt::object, qt::qml_element]] ElementCanvas : public QQuickPaintedItem {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    // Operations use logical pixels; the item scales them to its own.
    enum class [[qt::qenum]] Operation : std::uint8_t {
      move,
      line,
      curve,
      quad,
      arc,
      rect,
      round_rect,
      circle,
      path,
      close,
      fill,
      stroke,
      width,
      cap,
      join,
      alpha,
      translate,
      rotate,
      scale,
      save,
      restore,
    };
    explicit ElementCanvas(QQuickItem* parent = nullptr);
    [[nodiscard]] QVariantList operations() const;
    void setOperations(const QVariantList& operations);
    [[nodiscard]] qreal ratio() const noexcept;
    void setRatio(qreal ratio);
    void paint(QPainter* painter) override;

    // Parses the SVG path subset M L H V C Q Z, absolute and relative; anything else stops it.
    [[nodiscard]] static bool appendSvgPath(QPainterPath& path, const QString& data);

    [[qt::signal]] void operationsChanged();

  private:
    QVariantList operations_;
    qreal ratio_ = 1;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("operations", &ElementCanvas::operations).withWrite(&ElementCanvas::setOperations).withNotify(&ElementCanvas::operationsChanged),
        telar::qt::property("ratio", &ElementCanvas::ratio).withWrite(&ElementCanvas::setRatio).withNotify(&ElementCanvas::operationsChanged)
    );
  };

}
