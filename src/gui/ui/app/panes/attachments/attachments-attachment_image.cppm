export module telar.gui.ui.app.panes.attachments:attachment_image;

import telar.gui.qt;

export namespace telar::gui::qt {

  class [[qt::object, qt::qml_element]] AttachmentImage : public QQuickItem {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    explicit AttachmentImage(QQuickItem* parent = nullptr);
    [[nodiscard]] QImage image() const;
    void setImage(QImage image);
    [[nodiscard]] bool thumbnail() const noexcept;
    void setThumbnail(bool thumbnail);

    [[qt::signal]] void imageChanged();

  protected:
    QSGNode* updatePaintNode(QSGNode* previous, UpdatePaintNodeData* data) override;

  private:
    QImage image_;
    bool thumbnail_ = false;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("image", &AttachmentImage::image).withWrite(&AttachmentImage::setImage).withNotify(&AttachmentImage::imageChanged),
        telar::qt::property("thumbnail", &AttachmentImage::thumbnail).withWrite(&AttachmentImage::setThumbnail).withNotify(&AttachmentImage::imageChanged)
    );
  };

}
