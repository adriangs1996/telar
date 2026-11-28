export module telar.gui.ui.kit.fonts:window_font_catalog;

import std;
import telar.gui.qt;
import :font_asset;
import :font_collection;
import telar.gui.foundation.core;
import telar.gui.foundation.fonts;
import telar.wire.vocabulary;

export namespace telar::gui::qt {

  class [[qt::object]] WindowFontCatalog final : public QObject {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    explicit WindowFontCatalog(QQuickWindow& window);
    ~WindowFontCatalog() override;
    WindowFontCatalog(const WindowFontCatalog&) = delete;
    WindowFontCatalog& operator=(const WindowFontCatalog&) = delete;
    WindowFontCatalog(WindowFontCatalog&&) = delete;
    WindowFontCatalog& operator=(WindowFontCatalog&&) = delete;
    [[nodiscard]] static WindowFontCatalog& forWindow(QQuickWindow& window);
    [[nodiscard]] const std::shared_ptr<const FontCollection>& collection() const noexcept;
    [[nodiscard]] std::shared_ptr<const FontCollection> collectionFor(const std::shared_ptr<const FontAsset>& primary);
    [[nodiscard]] bool busy() const noexcept;
    void configure(const FontConfiguration& font);
    void request(std::string_view text, fonts::FontRole preferred, const std::shared_ptr<const FontCollection>& collection = {});

    [[qt::signal]] void fontsChanged();

  private:
    struct Discovery {
      fonts::FontQuery query;
      std::shared_ptr<const FontAsset> source;
      std::uint64_t generation = 0;
    };

    [[nodiscard]] static Discovery discover(fonts::FontQuery query, std::uint64_t generation);
    [[nodiscard]] bool adopt(const Discovery& result);
    void start();
    void complete();

    std::shared_ptr<const FontCollection> collection_;
    QHash<const FontAsset*, std::weak_ptr<const FontCollection>> primary_collections_;
    fonts::FontRequests requests_;
    QFutureWatcher<Discovery> task_;
    std::uint64_t generation_ = 0;
    bool running_ = false;
  };

}
