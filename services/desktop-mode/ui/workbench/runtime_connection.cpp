#include "runtime_connection.hpp"
#include "../../telar_client/codecs/telar_handshake.hpp"
#include <QElapsedTimer>
#include <QRandomGenerator>
#include <QDebug>
#include <QDir>
#include <algorithm>

namespace workbench {
  namespace {
    constexpr int reconnect_delay_ms = 1000;
    constexpr int snapshot_interval_ms = 1500;
    constexpr int handshake_timeout_ms = 5000;
    constexpr int request_timeout_ms = 10000;
    constexpr std::size_t pending_limit = 256;
    constexpr int resize_delay_ms = 30;
    constexpr qint64 read_budget_ms = 4;
    constexpr std::size_t decode_capacity = 512 * 1024;
    constexpr qsizetype input_chunk = 64 * 1024;
    constexpr telar::TerminalSize initial_size{80, 24, 8, 16};

    bool equal(telar::TerminalSize a, telar::TerminalSize b) {
      return a.cols == b.cols && a.rows == b.rows && a.cell_width_px == b.cell_width_px &&
             a.cell_height_px == b.cell_height_px;
    }
  } // namespace

  RuntimeConnection::RuntimeConnection(QString socket, telar::WorkspaceLocation workspace)
      : path_(std::move(socket)),
        workspace_(workspace),
        arena_(decode_capacity) {
    identity_ = QRandomGenerator::system()->generate64() | 1;
    clock_.start();
    socket_.setReadBufferSize(telar::max_payload_size + telar::frame_prefix_size);
    retry_.setSingleShot(true);
    retry_.setInterval(reconnect_delay_ms);
    deadline_.setSingleShot(true);
    deadline_.setInterval(handshake_timeout_ms);
    refresh_.setInterval(snapshot_interval_ms);
    resize_timer_.setSingleShot(true);
    resize_timer_.setInterval(resize_delay_ms);
    QObject::connect(&retry_, &QTimer::timeout, this, [this] {
      connect();
    });

    QObject::connect(&deadline_, &QTimer::timeout, this, [this] {
      error_ = "Runtime handshake timed out";
      socket_.abort();
      disconnected();
    });

    QObject::connect(&refresh_, &QTimer::timeout, this, [this] {
      refresh();
    });

    QObject::connect(&socket_, &QLocalSocket::connected, this, [this] {
      write(telar::HandshakeCodec::encode(telar::ClientHello{}));
    });

    QObject::connect(&socket_, &QLocalSocket::disconnected, this, [this] {
      disconnected();
    });

    QObject::connect(&socket_, &QLocalSocket::errorOccurred, this, [this](auto) {
      error_ = socket_.errorString();
      disconnected();
    });

    QObject::connect(&socket_, &QLocalSocket::readyRead, this, [this] {
      read();
    });

    QObject::connect(&resize_timer_, &QTimer::timeout, this, [this] {
      if (!ready()) {
        return;
      }

      for (const auto &[id, size] : sizes_) {
        if (attached_.contains(id) &&
            (!sent_sizes_.contains(id) || !equal(sent_sizes_.at(id), size))) {
          send(telar::PaneResize{id, size});
          sent_sizes_[id] = size;
        }
      }
    });
  }

  RuntimeConnection::~RuntimeConnection() {
    socket_.disconnect(this);
    socket_.abort();
  }

  void RuntimeConnection::connect() {
    if (!visible_ || socket_.state() != QLocalSocket::UnconnectedState) {
      return;
    }

    input_.clear();
    socket_.connectToServer(path_);
    deadline_.start();
  }

  void RuntimeConnection::disconnected() {
    handshake_ = false;
    attached_.clear();
    sent_sizes_.clear();
    pending_.clear();
    refresh_.stop();
    deadline_.stop();

    for (auto &[id, screen] : screens_) {
      screen->connected = false;
      if (painted) {
        painted(id);
      }
    }

    if (visible_) {
      retry_.start();
    }

    notify();
  }

  void RuntimeConnection::setVisible(bool visible) {
    if (visible_ == visible) {
      return;
    }

    visible_ = visible;

    if (visible) {
      connect();
    } else {
      retry_.stop();
      socket_.abort();
      disconnected();
      for (auto &[id, screen] : screens_) {
        screen->discard();
      }
    }
  }

  void RuntimeConnection::write(std::span<const telar::Byte> payload) {
    if (socket_.state() != QLocalSocket::ConnectedState) {
      return;
    }

    if (socket_.bytesToWrite() + static_cast<qint64>(payload.size()) > output_limit) {
      error_ = "Runtime input queue overflow; connection reset";
      socket_.abort();
      return;
    }

    std::array<telar::Byte, telar::frame_prefix_size> prefix;
    auto output = std::span<telar::Byte>{prefix};
    telar::u32::encode(static_cast<std::uint32_t>(payload.size()), output);
    socket_.write(reinterpret_cast<const char *>(prefix.data()), prefix.size());
    socket_.write(reinterpret_cast<const char *>(payload.data()), payload.size());
  }

  void RuntimeConnection::read() {
    if (reading_) {
      return;
    }

    reading_ = true;
    QElapsedTimer budget;
    budget.start();

    try {
      while (socket_.state() == QLocalSocket::ConnectedState) {
        const auto capacity =
            static_cast<qsizetype>(telar::max_payload_size + telar::frame_prefix_size);
        if (input_.size() < capacity) {
          input_ += socket_.read(capacity - input_.size());
        }

        if (input_.size() < static_cast<qsizetype>(telar::frame_prefix_size)) {
          break;
        }

        auto bytes =
            std::span<const telar::Byte>{reinterpret_cast<const telar::Byte *>(input_.constData()),
                                         static_cast<std::size_t>(input_.size())};
        const auto length = telar::u32::decode(bytes);
        if (!length || length > telar::max_payload_size) {
          throw std::runtime_error("Invalid runtime frame size");
        }

        if (bytes.size() < length) {
          break;
        }

        consume(bytes.first(length));
        input_.remove(0, length + telar::frame_prefix_size);
        if (budget.elapsed() >= read_budget_ms) {
          QTimer::singleShot(0, this, [this] {
            read();
          });

          break;
        }
      }
    } catch (const std::exception &error) {
      error_ = QString::fromUtf8(error.what());
      socket_.abort();
    }

    reading_ = false;
  }

  void RuntimeConnection::consume(std::span<const telar::Byte> payload) {
    if (!handshake_) {
      const auto response = telar::HandshakeCodec::decodeResponse(payload);
      const auto *accepted = std::get_if<telar::ServerAccept>(&response);
      if (!accepted || accepted->schema != telar::handshake::schema_id) {
        throw std::runtime_error("Runtime rejected the desktop protocol");
      }

      handshake_ = true;
      error_.clear();
      deadline_.stop();
      send(telar::RequestRuntimeState{identity_, true});
      refresh();
      refresh_.start();
      notify();
      return;
    }

    telar::DecodeStorage storage{arena_};
    switch (static_cast<telar::ServerTag>(payload.front())) {
    case telar::ServerTag::workspace_snapshot: {
      const auto value = telar::Codec::decode<telar::WorkspaceSnapshot>(payload, storage);
      if (!pending_.erase(value.request_id)) {
        break;
      }

      std::set<std::uint64_t> live;
      for (const auto &tab : value.tabs) {
        live.insert(tab.tab_id);
        tabs_.try_emplace(tab.tab_id);
      }

      std::erase_if(tabs_, [&](const auto &entry) {
        return !live.contains(entry.first);
      });

      if (!live.contains(active_tab_)) {
        active_tab_ = value.tabs.empty() ? 0 : value.tabs.front().tab_id;
      }

      if (active_tab_) {
        requestTab(active_tab_);
      }

      synchronizeAttachments();
      notify();
      break;
    }
    case telar::ServerTag::tab_snapshot: {
      const auto value = telar::Codec::decode<telar::TabSnapshot>(payload, storage);
      if (!pending_.erase(value.request_id)) {
        break;
      }

      if (!tabs_.contains(value.location.tab_id)) {
        break;
      }

      auto &panes = tabs_[value.location.tab_id];
      panes.clear();
      for (const auto &pane : value.panes) {
        panes.push_back(pane.pane_id);
      }

      snapshots_.insert(value.location.tab_id);
      synchronizeAttachments();
      notify();
      break;
    }
    case telar::ServerTag::pane_opened: {
      const auto value = telar::Codec::decode<telar::PaneOpened>(payload, storage);
      pending_.erase(value.request_id);
      if (value.created) {
        auto &panes = tabs_[value.location.tab_id];
        if (std::find(panes.begin(), panes.end(), value.pane_id) == panes.end()) {
          panes.push_back(value.pane_id);
        }
      }

      attached_.insert(value.pane_id);
      synchronizeAttachments();
      resize_timer_.start();
      notify();
      break;
    }
    case telar::ServerTag::pane_frame: {
      const auto value = telar::Codec::decode<telar::PaneFrame>(payload, storage);
      if (!attached_.contains(value.pane_id)) {
        break;
      }

      auto target = screen(value.pane_id);
      if (target->apply(value)) {
        if (painted) {
          painted(value.pane_id);
        }

        send(telar::FrameAck{value.pane_id, value.frame_id});
      } else {
        send(telar::RequestSnapshot{value.pane_id, target->frame});
      }

      break;
    }
    case telar::ServerTag::pane_exited: {
      const auto value = telar::Codec::decode<telar::PaneExited>(payload, storage);
      std::erase_if(pending_, [&](const auto &entry) {
        return entry.second.kind == RequestKind::close && entry.second.target == value.pane_id;
      });

      for (auto &[id, panes] : tabs_) {
        std::erase(panes, value.pane_id);
      }

      attached_.erase(value.pane_id);
      screens_.erase(value.pane_id);
      sizes_.erase(value.pane_id);
      sent_sizes_.erase(value.pane_id);
      notify();
      refresh();
      break;
    }
    case telar::ServerTag::request_failed: {
      const auto value = telar::Codec::decode<telar::RequestFailed>(payload, storage);
      const auto pending = pending_.find(value.request_id);
      if (pending != pending_.end()) {
        if (pending->second.kind == RequestKind::attach) {
          attached_.erase(pending->second.target);
        }

        pending_.erase(pending);
      }

      error_ = QString::fromUtf8(value.message.data(), value.message.size());
      qWarning().noquote() << "Workbench runtime request failed:" << error_;
      notify();
      break;
    }
    case telar::ServerTag::request_completed: {
      const auto value = telar::Codec::decode<telar::RequestCompleted>(payload, storage);
      pending_.erase(value.request_id);
      refresh();
      break;
    }
    case telar::ServerTag::tab_closed: {
      const auto value = telar::Codec::decode<telar::TabClosed>(payload, storage);
      pending_.erase(value.request_id);
      tabs_.erase(value.location.tab_id);
      snapshots_.erase(value.location.tab_id);
      synchronizeAttachments();
      refresh();
      notify();
      break;
    }
    case telar::ServerTag::resync_required:
      refresh();
      sent_sizes_.clear();
      resize_timer_.start();
      for (const auto pane : attached_) {
        send(telar::RequestSnapshot{pane, 0});
      }

      break;
    case telar::ServerTag::runtime_stopping:
      socket_.abort();
      break;
    default:
      break;
    }
  }

  void RuntimeConnection::refresh() {
    if (!ready()) {
      return;
    }

    for (const auto &[id, pending] : pending_) {
      if (clock_.elapsed() - pending.started > request_timeout_ms) {
        error_ = "Runtime request timed out; reconnecting without replaying mutations";
        socket_.abort();
        return;
      }
    }

    if (!waiting(RequestKind::workspace)) {
      send(telar::RequestWorkspaceSnapshot{request(RequestKind::workspace), workspace_});
    }
  }

  std::uint64_t RuntimeConnection::request(RequestKind kind, std::uint64_t target) {
    if (pending_.size() >= pending_limit) {
      throw std::runtime_error("Too many pending runtime requests");
    }

    const auto id = request_++;
    pending_.emplace(id, Pending{kind, target, clock_.elapsed()});
    return id;
  }

  bool RuntimeConnection::waiting(RequestKind kind, std::uint64_t target) const {
    return std::any_of(pending_.begin(), pending_.end(), [&](const auto &entry) {
      return entry.second.kind == kind && entry.second.target == target;
    });
  }

  void RuntimeConnection::requestTab(std::uint64_t tab) {
    if (tab && !waiting(RequestKind::tab, tab)) {
      send(telar::RequestTabSnapshot{request(RequestKind::tab, tab), {workspace_, tab}});
    }
  }

  void RuntimeConnection::selectTab(std::uint64_t tab) {
    if (active_tab_ == tab) {
      return;
    }

    active_tab_ = tab;
    synchronizeAttachments();
    if (ready() && tab) {
      requestTab(tab);
    }
  }

  void RuntimeConnection::synchronizeAttachments() {
    if (!ready() || (active_tab_ && !snapshots_.contains(active_tab_))) {
      return;
    }

    std::set<std::uint64_t> wanted;
    if (tabs_.contains(active_tab_)) {
      wanted.insert(tabs_.at(active_tab_).begin(), tabs_.at(active_tab_).end());
    }

    for (auto it = attached_.begin(); it != attached_.end();) {
      if (!wanted.contains(*it)) {
        send(telar::DetachPane{*it});
        if (screens_.contains(*it)) {
          screens_.at(*it)->discard();
        }

        sent_sizes_.erase(*it);
        it = attached_.erase(it);
      } else {
        ++it;
      }
    }

    for (const auto pane : wanted) {
      attach(pane);
    }
  }

  void RuntimeConnection::attach(std::uint64_t pane) {
    if (!ready() || attached_.contains(pane)) {
      return;
    }

    attached_.insert(pane);
    send(telar::OpenPane{request(RequestKind::attach, pane),
                         {telar::PaneTarget::Kind::pane, pane},
                         sizes_.contains(pane) ? sizes_.at(pane) : initial_size,
                         {}});
  }

  void RuntimeConnection::input(std::uint64_t pane, const QByteArray &bytes) {
    if (!ready() || !attached_.contains(pane) || !screen(pane)->connected) {
      return;
    }

    const auto overhead = (bytes.size() / input_chunk + 1) *
                          (telar::frame_prefix_size + sizeof(pane) + sizeof(telar::Byte));
    if (bytes.size() + overhead + socket_.bytesToWrite() > output_limit) {
      error_ = "Input exceeds the available queue capacity; nothing was sent";
      notify();
      return;
    }

    for (qsizetype offset = 0; offset < bytes.size(); offset += input_chunk) {
      const auto part = bytes.sliced(offset, std::min(input_chunk, bytes.size() - offset));
      send(telar::PaneInput{pane,
                            {reinterpret_cast<const telar::Byte *>(part.constData()),
                             static_cast<std::size_t>(part.size())}});
    }
  }

  void RuntimeConnection::resize(std::uint64_t pane, telar::TerminalSize size) {
    if (sizes_.contains(pane) && equal(sizes_.at(pane), size)) {
      return;
    }

    sizes_[pane] = size;
    resize_timer_.start();
  }

  void RuntimeConnection::viewport(std::uint64_t pane, std::uint32_t offset) {
    if (ready() && attached_.contains(pane)) {
      send(telar::SetPaneViewport{pane, offset});
    }
  }

  void RuntimeConnection::split(std::uint64_t source) {
    if (!ready() || !active_tab_ || !hasSnapshot(active_tab_)) {
      throw std::runtime_error("Workspace is waiting for its tab snapshot");
    }

    if (waiting(RequestKind::create)) {
      throw std::runtime_error("A pane is already being created");
    }

    const auto &panes = tabs_.at(active_tab_);
    if (!source && !panes.empty()) {
      source = panes.front();
    }

    if (!attached_.contains(source) ||
        std::find(panes.begin(), panes.end(), source) == panes.end()) {
      throw std::runtime_error("Split requires an attached terminal in the active tab");
    }

    auto shell = qEnvironmentVariable("SHELL").toStdString();
    if (shell.empty() || shell.front() != '/') {
      shell = "/bin/sh";
    }

    const std::string_view name = std::string_view(shell).substr(shell.find_last_of('/') + 1);
    constexpr std::array<std::string_view, 6> login_shells{"sh",
                                                           "bash",
                                                           "zsh",
                                                           "ksh",
                                                           "dash",
                                                           "fish"};
    const bool login = std::ranges::find(login_shells, name) != login_shells.end();
    const std::array<std::string_view, 3> arguments{shell, "-l", "-i"};
    const auto cwd = QDir::homePath().toStdString();
    // The runtime resolves cwd_source from its live pane, keeping directory authority there.
    const telar::Launch launch{cwd,
                               source,
                               std::span(arguments).first(login ? arguments.size() : 1)};
    const auto request_id = request(RequestKind::create);
    try {
      send(telar::CreatePane{request_id, {workspace_, active_tab_}, initial_size, launch});
    } catch (...) {
      pending_.erase(request_id);
      throw;
    }
  }

  void RuntimeConnection::close(std::uint64_t pane) {
    if (ready() && !waiting(RequestKind::close, pane)) {
      send(telar::ClosePane{request(RequestKind::close, pane), pane});
    }
  }

  std::shared_ptr<TerminalScreen> RuntimeConnection::screen(std::uint64_t pane) {
    auto &value = screens_[pane];
    if (!value) {
      value = std::make_shared<TerminalScreen>();
    }

    return value;
  }

  const std::map<std::uint64_t, std::vector<std::uint64_t>> &RuntimeConnection::tabs() const {
    return tabs_;
  }

  std::uint64_t RuntimeConnection::activeTab() const {
    return active_tab_;
  }

  bool RuntimeConnection::ready() const {
    return visible_ && handshake_ && socket_.state() == QLocalSocket::ConnectedState;
  }

  bool RuntimeConnection::hasSnapshot(std::uint64_t tab) const {
    return snapshots_.contains(tab);
  }

  const QString &RuntimeConnection::error() const {
    return error_;
  }

  void RuntimeConnection::notify() {
    if (changed) {
      changed();
    }
  }
} // namespace workbench
