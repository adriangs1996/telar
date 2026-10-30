#pragma once

#include "application/dependencies.hpp"
#include "attachment_preview.hpp"
#include "attachments/capture_state.hpp"
#include "attachments/catalog.hpp"
#include "attachments/types.hpp"
#include "attachments/marker_screen.hpp"
#include "attachments/marker_removal.hpp"
#include "input/terminal_key.hpp"
#include "clipboard_images.hpp"
#include "machine_client_key.hpp"
#include "platform/clipboard_image_source.hpp"
#include <QImage>
#include <QObject>
#include <QString>
#include <QVariantList>
#include <QVariantMap>
#include <QtCore/qtypes.h>
#include <QtQml/qqmlregistration.h>
#include <cstdint>
#include <optional>

namespace telar::gui::qt {

struct AttachmentSource {
  MachineClientKey source;
  std::uint64_t runtime_generation = 0;

  bool operator==(const AttachmentSource &) const = default;
};

struct AttachmentPrompt {
  MachineClientKey source;
  std::uint64_t runtime_generation = 0;
  AttachmentTarget target;
  std::uint64_t attachment_generation = 0;
  AttachmentMarkerPolicy policy = AttachmentMarkerPolicy::ordered;
};

class AttachmentShelf final : public QObject {
  Q_OBJECT
  QML_NAMED_ELEMENT(AttachmentShelfController)
  QML_UNCREATABLE("Use the window's attachment shelf")
  Q_PROPERTY(QVariantList items READ items NOTIFY changed)
  Q_PROPERTY(QString paneId READ paneId NOTIFY changed)
  Q_PROPERTY(QVariantMap modal READ modal NOTIFY changed)

public:
  explicit AttachmentShelf(ApplicationAllocator &memory, QObject *parent = nullptr);
  ~AttachmentShelf() override = default;
  AttachmentShelf(const AttachmentShelf &) = delete;
  AttachmentShelf &operator=(const AttachmentShelf &) = delete;
  AttachmentShelf(AttachmentShelf &&) = delete;
  AttachmentShelf &operator=(AttachmentShelf &&) = delete;

  void setSource(AttachmentSource source);
  void setPrompt(std::optional<AttachmentPrompt> prompt, bool presented = true);
  void requestCapture();
  void clearPrompt(AttachmentTarget target);
  bool remove(std::uint64_t id);
  void observeKey(const TerminalKey &key, AttachmentMarkerScreen screen);
  void reconcile(AttachmentMarkerScreen screen);
  [[nodiscard]] AttachmentMarkerPlan removalPlan(std::uint64_t id, AttachmentMarkerScreen screen) const noexcept;
  [[nodiscard]] QVariantList items() const;
  [[nodiscard]] QString paneId() const;
  [[nodiscard]] QVariantMap modal() const;
  [[nodiscard]] const std::optional<AttachmentPrompt> &prompt() const noexcept;
  [[nodiscard]] const std::optional<AttachmentPrompt> &capturePrompt() const noexcept;
  [[nodiscard]] bool hasVisibleItems() const noexcept;
  Q_INVOKABLE QImage image(const QString &identity, bool full) const;
  Q_INVOKABLE void open(const QString &identity);
  Q_INVOKABLE void close();
  Q_INVOKABLE void dismiss(const QString &identity);

signals:
  void changed();
  void failed(const QString &message);
  void quotaReached(platform::ClipboardImageError error);
  void evicted(AttachmentEviction reason, qulonglong requested);
  void dismissRequested(qulonglong identity);
  void adopted(qulonglong pane_id);

private:
  struct Delivery {
    struct SlotState {
      AttachmentPreview preview;
    };

    [[nodiscard]] SlotState create();
    void retire(SlotState &slot) noexcept;
    [[nodiscard]] static bool canRelease(const SlotState &slot) noexcept;

    std::optional<AttachmentPreview> landing;
  };

  void complete();
  void adopt(ClipboardImageResult &result);
  [[nodiscard]] bool current(const ClipboardImageJob &job) const noexcept;

  ClipboardCaptureState captures_;
  std::optional<AttachmentPrompt> prompt_;
  std::optional<AttachmentPrompt> capture_prompt_;
  std::optional<AttachmentSource> source_;
  Delivery delivery_;
  AttachmentCatalog<ApplicationAllocator, Delivery> catalog_;
  ClipboardImages worker_;
};

}
