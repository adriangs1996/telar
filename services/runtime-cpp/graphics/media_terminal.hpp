#pragma once

#include "../diagnostics/trace.hpp"
#include "../terminal/control/parser.hpp"
#include "../terminal/control/classification.hpp"
#include "../terminal/pty_response_queue.hpp"
#include "../terminal/response_outbox.hpp"
#include "atomic_frame.hpp"
#include "file_input.hpp"
#include "limits.hpp"
#include "storage.hpp"
#include "upload_limits.hpp"
#include <charconv>

namespace telar::runtime {

template <Allocator Memory>
class MediaTerminal {
public:
  explicit MediaTerminal(Memory &memory, TerminalSize size, GraphicsLimits limits, std::shared_ptr<PtyResponseQueue> responses = {})
      : graphics(memory),
        control_parser_(memory),
        allocator_(memory),
        responses_(responses ? std::move(responses) : std::allocate_shared<PtyResponseQueue>(AllocatorRef<PtyResponseQueue, Memory>{memory})),
        response_outbox_(memory, *responses_),
        storage_limit_(limits.screenBytes()),
        uploads_(limits.screenBytes()) {
    checkGhostty(ghostty_terminal_new(allocator_.get(), terminal_.output(), size.cols, size.rows));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_USERDATA, this));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_WRITE_PTY, reinterpret_cast<const void *>(&receiveResponse)));
    const auto storage = limits.screenBytes();
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &storage));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_APC_MAX_BYTES_KITTY, &GraphicsLimits::payload_bytes));
    const bool disabled = false;
    const bool enabled = true;
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_GLYPH_PROTOCOL, &disabled));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_FILE, &disabled));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_TEMP_FILE, nullptr));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_SHARED_MEM, &enabled));
    resize(size);
  }

  void feed(std::span<const Byte> bytes) {
    try {
      requireOpen();
      const auto consumed = control_parser_.feed(bytes, *this);
      if (consumed != bytes.size()) {
        throw std::logic_error{"Media control filter failed to consume input"};
      }
      response_outbox_.drain();
    } catch (...) {
      response_failed_ |= !responses_->closed();
      responses_->stopProducing();
      control_parser_.discard();
      response_outbox_.discard();
      throw;
    }
  }

  void ordinary(std::span<const Byte> bytes) {
    GraphicsFileInput::feed(bytes, storage_limit_, *this);
  }

  bool enquire() const noexcept {
    return true;
  }

  bool streamable(control::Sequence sequence) const noexcept {
    return sequence.kind != control::Kind::apc && control::streamable(sequence);
  }

  bool complete(control::Sequence sequence) {
    if (sequence.kind == control::Kind::csi) {
      const auto parameters = control::Parameters::parse(sequence.body());
      if (parameters && !parameters->colon && parameters->modifiers() == "?" && (parameters->final == 'h' || parameters->final == 'l' || parameters->final == 's' || parameters->final == 'r')) {
        for (const auto mode : std::span{parameters->values}.first(parameters->count)) {
          if (std::find(control::desktop_modes.begin(), control::desktop_modes.end(), mode) == control::desktop_modes.end()) {
            control::forwardPrivateMode(mode, parameters->final, [this](auto command) { ordinary(command); });
          }
        }
        return true;
      }
    }
    if (!control::query(sequence)) {
      if (sequence.kind == control::Kind::apc) {
        GraphicsFileInput::frame(sequence.bytes, sequence.terminator(), storage_limit_, *this);
        return true;
      }
      ordinary(sequence.bytes);
      if (sequence.ending != control::Ending::final_byte) {
        const auto terminator = sequence.terminator();
        ordinary({reinterpret_cast<const Byte *>(terminator.data()), terminator.size()});
      }
    }
    return true;
  }

  void reply(std::span<const Byte> bytes) {
    response_outbox_.append(bytes);
    response_outbox_.drain();
  }

  void ingest(std::span<const Byte> bytes) {
    requireOpen();
    TELAR_TRACE("media.terminal.feed");
    write(bytes, uploads_.observe(terminal_.get(), bytes));
  }

  void ingestEncodedChunk(std::span<const Byte> bytes) {
    requireOpen();
    TELAR_TRACE("media.terminal.feed");
    write(bytes, uploads_.observeEncodedChunk(terminal_.get()));
  }

  void resize(TerminalSize size) {
    checkGhostty(ghostty_terminal_resize(terminal_.get(), size.cols, size.rows, size.cell_width_px, size.cell_height_px));
  }

  void refresh() {
    graphics.update(terminal_.get());
  }

  bool insertImage(const AtomicFrameControl &control, std::span<const Byte> data) noexcept {
    const GhosttyKittyGraphicsImageInsert image{
        .size = sizeof(GhosttyKittyGraphicsImageInsert),
        .image_id = control.key.image_id,
        .width = control.width,
        .height = control.height,
        .format = control.depth == 24 ? GHOSTTY_KITTY_IMAGE_FORMAT_RGB : GHOSTTY_KITTY_IMAGE_FORMAT_RGBA,
        .data = data.data(),
        .data_len = data.size(),
    };
    return ghostty_kitty_graphics_image_insert(terminal_.get(), &image) == GHOSTTY_SUCCESS;
  }

  ImageKey imageKey(std::uint32_t identity) {
    GhosttyKittyGraphics storage = nullptr;
    checkGhostty(ghostty_terminal_get(terminal_.get(), GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, &storage));
    const auto image = ghostty_kitty_graphics_image(storage, identity);
    ImageKey key{identity, 0};
    checkGhostty(ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_GENERATION, &key.generation));
    return key;
  }

#if TELAR_DIAGNOSTICS
  diagnostics::GraphicsStorageSnapshot storageMetrics() {
    return graphics.storageMetrics(terminal_.get());
  }
#endif

  std::size_t storageLimit() const noexcept {
    return storage_limit_;
  }

  std::span<const Byte> responses() const noexcept {
    return responses_->readable();
  }

  void consumeResponses(std::size_t count) noexcept {
    responses_->consume(count);
    response_outbox_.drain();
  }

  bool drainResponses() noexcept { return response_outbox_.drain(); }
  bool pendingResponses() const noexcept { return response_outbox_.pending(); }
  std::size_t nextResponseSize() const noexcept { return response_outbox_.nextSize(); }
  bool responseFailed() const noexcept { return response_failed_; }

  void requireOpen() const {
    if (responses_->closed()) {
      throw ResponseFailure{};
    }
  }

  GraphicsUploadLimits::Reached takeUploadLimits() noexcept {
    return uploads_.takeReached();
  }

  GraphicsStorage<Memory> graphics;

private:
  struct ResponseFailure {};

  void write(std::span<const Byte> bytes, const GraphicsUploadLimits::Observation &observation) {
    ghostty_terminal_vt_write(terminal_.get(), bytes.data(), bytes.size());
    if (response_failed_) {
      throw ResponseFailure{};
    }
    if (const auto image = uploads_.enforce(terminal_.get(), observation)) {
      replyUploadLimit(*image);
    }

    bool processing_error = false;
    checkGhostty(ghostty_terminal_get(terminal_.get(), GHOSTTY_TERMINAL_DATA_VT_PROCESSING_ERROR, &processing_error));
    if (processing_error) {
      throw TerminalError{GHOSTTY_OUT_OF_MEMORY};
    }
  }

  void replyUploadLimit(std::uint32_t image) {
    constexpr std::string_view prefix = "\x1b_Gi=";
    constexpr std::string_view suffix = ";ENOMEM: graphics upload limit exceeded\x1b\\";
    std::array<char, prefix.size() + 10 + suffix.size()> response;
    auto *identity = std::copy(prefix.begin(), prefix.end(), response.data());
    const auto formatted = std::to_chars(identity, identity + 10, image);
    const auto *end = std::copy(suffix.begin(), suffix.end(), formatted.ptr);
    reply({reinterpret_cast<const Byte *>(response.data()), static_cast<std::size_t>(end - response.data())});
  }

  static void receiveResponse(GhosttyTerminal, void *context, const Byte *bytes, std::size_t count) noexcept {
    constexpr std::string_view kitty_response = "\x1b_G";
    if (count < kitty_response.size() || std::memcmp(bytes, kitty_response.data(), kitty_response.size()) != 0) {
      return;
    }

    auto &self = *static_cast<MediaTerminal *>(context);
    try {
      self.response_outbox_.append({bytes, count});
    } catch (...) {
      // No exception may cross the foreign callback. The enclosing write
      // fails after it returns, cancelling this pane generation explicitly.
      self.response_failed_ = true;
      self.responses_->stopProducing();
    }
  }

  control::Parser<Memory> control_parser_;
  GhosttyAllocatorBridge<Memory> allocator_;
  TerminalHandle terminal_;
  std::shared_ptr<PtyResponseQueue> responses_;
  ResponseOutbox<Memory> response_outbox_;
  std::size_t storage_limit_;
  GraphicsUploadLimits uploads_;
  bool response_failed_ = false;
};

}
