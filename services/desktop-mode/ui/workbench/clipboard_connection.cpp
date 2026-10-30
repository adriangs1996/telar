#include "runtime_connection.hpp"
#include "clipboard_consent.hpp"
#include "clipboard_provider.hpp"
#include "clipboard_paste.hpp"
#include <QPointer>

namespace workbench {
  void RuntimeConnection::paste(std::uint64_t pane, bool listing_only) {
    pasteFrom(pane, listing_only, [](bool listing) {
      const auto *clipboard = QGuiApplication::clipboard();
      return readClipboardPaste(clipboard != nullptr ? clipboard->mimeData() : nullptr, listing);
    });
  }

  void RuntimeConnection::sendPaste(std::uint64_t pane, const QString &text, const QStringList &available, bool listing_only) {
    const auto generation = generations_.find(pane);
    if (!ready() || !attached_.contains(pane) || generation == generations_.end()) {
      return;
    }
    if (!listing_only && static_cast<std::size_t>(text.size()) > telar::clipboard_content_limit) {
      error_ = "Paste exceeds the clipboard limit";
      notify();
      return;
    }
    const auto encoded = listing_only ? QByteArray{} : text.toUtf8();
    if (static_cast<std::size_t>(encoded.size()) > telar::clipboard_content_limit) {
      error_ = "Paste exceeds the clipboard limit";
      notify();
      return;
    }
    std::array<QByteArray, 16> encoded_mimes;
    std::array<std::string_view, 16> mimes;
    std::size_t count = 0;
    for (const auto &mime : available) {
      if (mime.isEmpty() || mime.size() > 256) {
        continue;
      }
      const auto bytes = mime.toUtf8();
      if (bytes.isEmpty() || bytes.size() > 256) {
        continue;
      }
      encoded_mimes[count] = bytes;
      mimes[count] = {encoded_mimes[count].constData(), static_cast<std::size_t>(bytes.size())};
      if (++count == mimes.size()) {
        break;
      }
    }
    send(telar::PastePaneClipboard{.request_id = request_++, .pane_id = pane, .pane_generation = generation->second, .listing_only = listing_only, .text = {reinterpret_cast<const telar::Byte *>(encoded.constData()), static_cast<std::size_t>(encoded.size())}, .available = std::span{mimes}.first(count)});
  }

  void RuntimeConnection::cancelClipboard(std::uint64_t pane) {
    std::erase_if(clipboard_operations_, [pane](const auto &entry) { return entry.second->task.ticket.pane_id == pane; });
  }

  void RuntimeConnection::clipboardRequest(const telar::ClipboardDesktopRequest &request) {
    const auto nonce = request.ticket.nonce;
    const auto generation = generations_.find(request.ticket.pane_id);
    if (generation == generations_.end() || generation->second != request.ticket.pane_generation || !attached_.contains(request.ticket.pane_id) || clipboard_operations_.contains(nonce)) {
      return;
    }
    if (clipboard_operations_.size() >= 32) {
      send(telar::CompleteClipboardDesktop{.ticket = request.ticket, .prepared = true});
      return;
    }
    const auto ticket = request.ticket;
    const auto epoch = clipboard_epoch_;
    auto operation = std::make_unique<DesktopClipboardOperation>(request, epoch);
    const bool prompt = operation->task.prompt;
    clipboard_operations_.emplace(nonce, std::move(operation));
    if (!prompt) {
      completeClipboard(ticket, epoch, ClipboardConsent::once);
      return;
    }
    const QPointer<RuntimeConnection> connection{this};
    QTimer::singleShot(0, this, [connection, nonce, ticket, epoch] {
      try {
        if (!connection || connection->clipboard_epoch_ != epoch) {
          return;
        }
        const auto found = connection->clipboard_operations_.find(nonce);
        if (found == connection->clipboard_operations_.end() || found->second->task.ticket != ticket || found->second->prepared) {
          return;
        }
        const auto task = found->second->task;
        // Platform selection support is a capability, not clipboard content.
        // Reject an unavailable location before asking for consent.
        const bool supported = QtClipboardProvider{}.supports(task.primary);
        if (!connection || connection->clipboard_epoch_ != epoch) {
          return;
        }
        const auto checked = connection->clipboard_operations_.find(nonce);
        if (checked == connection->clipboard_operations_.end() || checked->second->task.ticket != task.ticket) {
          return;
        }
        if (!supported) {
          connection->clipboard_operations_.erase(checked);
          connection->send(telar::CompleteClipboardDesktop{.ticket = task.ticket, .status = telar::ClipboardDesktopStatus::unsupported, .prepared = true});
          return;
        }
        DesktopClipboardOperation::Prompt prompt{new ClipboardConsentWindow(task, *connection, [connection, ticket, epoch](ClipboardConsent consent) {
          if (connection) {
            connection->completeClipboard(ticket, epoch, consent);
          }
        })};
        if (!connection || connection->clipboard_epoch_ != epoch) {
          return;
        }
        const auto current = connection->clipboard_operations_.find(nonce);
        if (current != connection->clipboard_operations_.end() && current->second->task.ticket == task.ticket) {
          current->second->prompt = std::move(prompt);
        }
      } catch (const std::bad_alloc &) {
        if (connection && connection->clipboard_epoch_ == epoch) {
          connection->completeClipboard(ticket, epoch, ClipboardConsent::deny);
        }
      }
    });
    QTimer::singleShot(30000, this, [connection, ticket, epoch] {
      if (connection) {
        connection->completeClipboard(ticket, epoch, ClipboardConsent::deny);
      }
    });
  }

  void RuntimeConnection::completeClipboard(telar::ClipboardTicket ticket, std::uint64_t expected_epoch, ClipboardConsent consent) {
    if (expected_epoch != clipboard_epoch_) {
      return;
    }
    const auto nonce = ticket.nonce;
    const auto found = clipboard_operations_.find(nonce);
    if (found == clipboard_operations_.end() || found->second->task.ticket != ticket) {
      return;
    }
    auto &operation = *found->second;
    if (operation.epoch != clipboard_epoch_ || !ready()) {
      clipboard_operations_.erase(found);
      return;
    }
    if (operation.prepared && consent != ClipboardConsent::deny) {
      return;
    }
    const bool remember = operation.task.rememberable && consent == ClipboardConsent::session;
    auto prompt = std::move(operation.prompt);
    const QPointer<RuntimeConnection> connection{this};
    const auto epoch = clipboard_epoch_;
    prompt.reset();
    if (!connection || connection->clipboard_epoch_ != epoch) {
      return;
    }
    const auto current = connection->clipboard_operations_.find(nonce);
    if (current == connection->clipboard_operations_.end() || current->second->task.ticket != ticket) {
      return;
    }
    current->second->consent = consent;
    current->second->prepared = true;
    if (consent == ClipboardConsent::deny) {
      connection->clipboard_operations_.erase(current);
    }
    // No desktop resource is inspected until a fresh runtime commit arrives.
    connection->send(telar::CompleteClipboardDesktop{.ticket = ticket, .status = consent == ClipboardConsent::deny ? telar::ClipboardDesktopStatus::denied : telar::ClipboardDesktopStatus::success, .remember = remember, .prepared = true});
  }

  void RuntimeConnection::cancelClipboardTask(const telar::CancelClipboardDesktop &cancellation) {
    const auto found = clipboard_operations_.find(cancellation.ticket.nonce);
    if (found != clipboard_operations_.end() && found->second->task.ticket == cancellation.ticket) {
      clipboard_operations_.erase(found);
    }
  }

  void RuntimeConnection::executeClipboardTask(telar::ClipboardDesktopExecute execution, std::uint64_t expected_epoch) {
    if (expected_epoch != clipboard_epoch_) {
      return;
    }

    const auto found = clipboard_operations_.find(execution.ticket.nonce);
    if (found == clipboard_operations_.end() || !found->second->prepared || found->second->task.ticket != execution.ticket) {
      return;
    }
    auto operation = std::move(found->second);
    clipboard_operations_.erase(found);
    const auto &task = operation->task;
    const auto generation = generations_.find(task.ticket.pane_id);
    const auto desktop = desktop_.find(task.ticket.pane_id);
    if (!ready() || operation->epoch != clipboard_epoch_ || !attached_.contains(task.ticket.pane_id) || generation == generations_.end() || generation->second != task.ticket.pane_generation || desktop == desktop_.end() || !desktop->second.visible || !desktop->second.clipboard) {
      return;
    }
    const QPointer<RuntimeConnection> connection{this};
    const auto epoch = clipboard_epoch_;
    QtClipboardProvider provider;
    auto result = workbench::executeClipboard(task, operation->consent, provider);
    if (!connection || connection->clipboard_epoch_ != epoch || !connection->ready()) {
      return;
    }
    const auto current_generation = connection->generations_.find(task.ticket.pane_id);
    if (!connection->attached_.contains(task.ticket.pane_id) || current_generation == connection->generations_.end() || current_generation->second != task.ticket.pane_generation) {
      return;
    }
    std::array<telar::ClipboardRepresentation, 4> contents;
    std::array<std::string_view, 16> available;
    for (std::size_t index = 0; index < result.contents.size(); ++index) {
      contents[index] = {result.contents[index].mime, result.contents[index].data};
    }
    for (std::size_t index = 0; index < result.available.size(); ++index) {
      available[index] = result.available[index];
    }
    connection->send(telar::CompleteClipboardDesktop{.ticket = task.ticket, .status = result.status, .contents = std::span{contents}.first(result.contents.size()), .available = std::span{available}.first(result.available.size())});
  }

}
