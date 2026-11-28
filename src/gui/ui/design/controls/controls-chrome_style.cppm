export module telar.gui.ui.design.controls:chrome_style;

import std;
import telar.gui.qt;
import telar.gui.foundation.core;
import telar.gui.foundation.drawing;

export namespace telar::gui::qt {

  class [[qt::object, qt::qml_element, qt::qml_singleton]] ChromeStyle final : public QObject {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    enum class QmlIsSingleton : quint8 {
      yes = 1,
    };

    void qt_qmlMarker_singleton();

    [[tbc::hot_path]] inline explicit ChromeStyle(QObject* parent = nullptr)
        : QObject(parent) {}

    [[tbc::hot_path]] [[nodiscard]] inline static qreal smallRadius() noexcept {
      return static_cast<qreal>(gui::ChromeStyle::small_radius);
    }

    [[tbc::hot_path]] [[nodiscard]] inline static qreal controlRadius() noexcept {
      return static_cast<qreal>(gui::ChromeStyle::control_radius);
    }

    [[tbc::hot_path]] [[nodiscard]] inline static qreal surfaceRadius() noexcept {
      return static_cast<qreal>(gui::ChromeStyle::surface_radius);
    }

    [[tbc::hot_path]] [[nodiscard]] inline static qreal dialogRadius() noexcept {
      return static_cast<qreal>(gui::ChromeStyle::dialog_radius);
    }

    [[tbc::hot_path]] [[nodiscard]] inline static qreal hoverAlpha() noexcept {
      return static_cast<qreal>(gui::ChromeStyle::hover_alpha);
    }

    [[tbc::hot_path]] [[nodiscard]] inline static qreal selectionAlpha() noexcept {
      return static_cast<qreal>(gui::ChromeStyle::selection_alpha);
    }

    [[tbc::hot_path]] [[nodiscard]] inline static qreal outlineAlpha() noexcept {
      return static_cast<qreal>(gui::ChromeStyle::outline_alpha);
    }

    [[tbc::hot_path]] [[nodiscard]] inline static qreal focusAlpha() noexcept {
      return static_cast<qreal>(gui::ChromeStyle::focus_alpha);
    }

    [[tbc::hot_path]] [[nodiscard]] inline static qreal wellAlpha() noexcept {
      return static_cast<qreal>(gui::ChromeStyle::well_alpha);
    }

    [[tbc::hot_path]] [[nodiscard]] inline static qreal menuRowPadding() noexcept {
      return static_cast<qreal>(gui::ChromeStyle::menu_row_padding);
    }

    [[tbc::hot_path]] [[nodiscard]] inline static qreal menuRowVerticalPadding() noexcept {
      return static_cast<qreal>(gui::ChromeStyle::menu_row_vertical_padding);
    }

    [[tbc::hot_path]] [[nodiscard]] inline static qreal menuMark() noexcept {
      return static_cast<qreal>(gui::ChromeStyle::menu_mark);
    }

    [[tbc::hot_path]] [[nodiscard]] inline static qreal menuGap() noexcept {
      return static_cast<qreal>(gui::ChromeStyle::menu_gap);
    }

    // `ink` moved the least it must to read at `ratio` on the opaque `ground`; the chrome's
    // secondary text and the marks' letters ask it, so every theme keeps them readable.
    [[tbc::hot_path]] [[qt::invokable]] [[nodiscard]] inline static QColor legible(const QColor& ink, const QColor& ground, qreal ratio) noexcept {
      const auto color = [](const QColor& source) {
        return gui::Color{.r = source.redF(), .g = source.greenF(), .b = source.blueF(), .a = source.alphaF()};
      };

      const auto result = gui::legible(color(ink), color(ground), static_cast<float>(ratio));

      return QColor::fromRgbF(result.r, result.g, result.b, result.a);
    }

    // The height of a line of chrome text at `pixel_size`, the one the machine rows are laid out
    // with, so a menu drawn in QML stacks its lines as they do.
    [[tbc::hot_path]] [[qt::invokable]] [[nodiscard]] inline static qreal lineHeight(qreal pixel_size) noexcept {
      return static_cast<qreal>(gui::ChromeMetrics::lineHeight(static_cast<std::uint16_t>(std::lround(pixel_size))));
    }

    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("smallRadius", &ChromeStyle::smallRadius).constant(),
        telar::qt::property("controlRadius", &ChromeStyle::controlRadius).constant(),
        telar::qt::property("surfaceRadius", &ChromeStyle::surfaceRadius).constant(),
        telar::qt::property("dialogRadius", &ChromeStyle::dialogRadius).constant(),
        telar::qt::property("hoverAlpha", &ChromeStyle::hoverAlpha).constant(),
        telar::qt::property("selectionAlpha", &ChromeStyle::selectionAlpha).constant(),
        telar::qt::property("outlineAlpha", &ChromeStyle::outlineAlpha).constant(),
        telar::qt::property("focusAlpha", &ChromeStyle::focusAlpha).constant(),
        telar::qt::property("wellAlpha", &ChromeStyle::wellAlpha).constant(),
        telar::qt::property("menuRowPadding", &ChromeStyle::menuRowPadding).constant(),
        telar::qt::property("menuRowVerticalPadding", &ChromeStyle::menuRowVerticalPadding).constant(),
        telar::qt::property("menuMark", &ChromeStyle::menuMark).constant(),
        telar::qt::property("menuGap", &ChromeStyle::menuGap).constant()
    );
  };

}
