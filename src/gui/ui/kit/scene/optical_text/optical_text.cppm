export module telar.gui.ui.kit.scene.optical_text;

import std;
import telar.gui.qt;

export namespace telar::gui::qt {
  class OpticalText final {
  public:
    OpticalText();
    ~OpticalText();
    OpticalText(const OpticalText&) = delete;
    OpticalText& operator=(const OpticalText&) = delete;
    OpticalText(OpticalText&&) = delete;
    OpticalText& operator=(OpticalText&&) = delete;

    static std::unique_ptr<OpticalText> create();
    void begin(QSizeF size, qreal scale, std::uint8_t strength);
    void add(const QTextLayout& layout, QPointF position, QColor color);
    [[nodiscard]] QImage snapshot() const;
    QSGNode* node(QQuickWindow& window, QPointF position);

  private:
    struct State;
    std::unique_ptr<State> state_;
  };
}
