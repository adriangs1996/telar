#include "ui/workbench/clipboard_consent.hpp"
#include "ui/workbench/clipboard_provider.hpp"
#include <QGuiApplication>
#include <cstdio>
#include <cstdlib>

using namespace workbench;

namespace {
void require(bool condition) {
  if (!condition) {
    std::abort();
  }
}

void press(ClipboardConsentWindow &window, QPointF point) {
  auto *content = window.contentItem()->childItems().front();
  QMouseEvent event{QEvent::MouseButtonPress, point, point, Qt::LeftButton, Qt::LeftButton, Qt::NoModifier};
  QCoreApplication::sendEvent(content, &event);
}

OwnedClipboardTask task(bool rememberable) {
  return OwnedClipboardTask{telar::ClipboardDesktopRequest{
      .ticket = {7, 11, 13, 17}, .prompt = true, .rememberable = rememberable,
      .name = "Untrusted\nname\x1b[31m",
  }};
}

void decisions() {
  QObject context;
  for (unsigned button = 0; button < 3; ++button) {
    unsigned answers = 0;
    ClipboardConsent answer = ClipboardConsent::deny;
    auto request = task(true);
    auto window = std::make_unique<ClipboardConsentWindow>(request, context, [&](ClipboardConsent consent) {
      ++answers;
      answer = consent;
    });
    QCoreApplication::processEvents();
    press(*window, {80.0 + button * 168.0, 176});
    require(answers == 0);
    // The posted decision owns no pointer to the destroyed input surface.
    window.reset();
    QCoreApplication::processEvents();
    require(answers == 1 && answer == static_cast<ClipboardConsent>(button));
  }
  unsigned answers = 0;
  auto request = task(false);
  ClipboardConsentWindow window{request, context, [&](ClipboardConsent consent) {
    require(consent == ClipboardConsent::deny);
    ++answers;
  }};
  QCoreApplication::processEvents();
  press(window, {420, 176});
  QCoreApplication::processEvents();
  require(answers == 0);
  window.close();
  QCoreApplication::processEvents();
  require(answers == 1);
}

void inMemoryMimeReads() {
  QMimeData source;
  QString text(4095, QChar{'x'});
  text += QString::fromUtf8("界𝄞");
  text += QString(4096, QChar{'y'});
  source.setText(text);
  const std::array<std::string_view, 1> mimes{"text/plain"};
  OwnedClipboardTask request{telar::ClipboardDesktopRequest{.ticket = {7, 11, 13, 17}, .mimes = mimes}};
  auto result = QtClipboardProvider::readData(&source, request);
  const auto expected = text.toUtf8();
  require(result.status == telar::ClipboardDesktopStatus::success && result.contents.size() == 1);
  require(std::string_view{reinterpret_cast<const char *>(result.contents[0].data.data()), result.contents[0].data.size()} == std::string_view{expected.constData(), static_cast<std::size_t>(expected.size())});
  source.setText(QString(telar::clipboard_content_limit + 1, QChar{'x'}));
  result = QtClipboardProvider::readData(&source, request);
  require(result.status == telar::ClipboardDesktopStatus::failure && result.contents.empty());
}

class ChangingMimeData final : public QMimeData {
public:
  explicit ChangingMimeData(std::function<void()> change) : change_(std::move(change)) {}
  QStringList formats() const override { return {QStringLiteral("application/test")}; }

protected:
  QVariant retrieveData(const QString &, QMetaType) const override {
    auto change = change_;
    change();
    return QByteArray{"owned result"};
  }

private:
  std::function<void()> change_;
};

void invalidatedMimeView() {
  std::unique_ptr<QMimeData> source;
  source = std::make_unique<ChangingMimeData>([&source] { source = std::make_unique<QMimeData>(); });
  const std::array<std::string_view, 1> mimes{"application/test"};
  OwnedClipboardTask request{telar::ClipboardDesktopRequest{.ticket = {7, 11, 13, 17}, .mimes = mimes}};
  const auto result = QtClipboardProvider::readData(source.get(), request);
  require(result.status == telar::ClipboardDesktopStatus::failure && result.contents.empty());
}

class OversizedMimeData final : public QMimeData {
public:
  mutable std::size_t materialized = 0;
  QStringList formats() const override { return {QStringLiteral("application/oversized")}; }

protected:
  QVariant retrieveData(const QString &, QMetaType) const override {
    QByteArray bytes(16 * 1024 * 1024, 'x');
    materialized = static_cast<std::size_t>(bytes.size());
    return bytes;
  }
};

void materializationLimitReproduction() {
  OversizedMimeData source;
  const std::array<std::string_view, 1> mimes{"application/oversized"};
  OwnedClipboardTask request{telar::ClipboardDesktopRequest{.ticket = {7, 11, 13, 17}, .mimes = mimes}};
  const auto result = QtClipboardProvider::readData(&source, request);
  require(result.status == telar::ClipboardDesktopStatus::failure && result.contents.empty());
  require(source.materialized == 16 * 1024 * 1024);
  std::printf("{\"case\":\"qt_materialization_before_bound\",\"payload_limit\":%zu,\"materialized_before_rejection\":%zu,\"source\":\"in_memory_QMimeData\"}\n", telar::clipboard_content_limit, source.materialized);
}
}

int main(int argc, char **argv) {
  QGuiApplication application{argc, argv};
  decisions();
  inMemoryMimeReads();
  invalidatedMimeView();
  materializationLimitReproduction();
  std::puts("Offscreen clipboard consent and in-memory MIME lifetime tests passed");
}
