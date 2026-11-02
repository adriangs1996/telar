#pragma once

#include "../plugins/frame_reader.hpp"
#include "../plugins/frame_writer.hpp"
#include "recording_protocol.hpp"
#include "../redirect/direction.hpp"
#include <optional>
#include <array>

namespace telar::runtime::traffic::control {

inline constexpr std::string_view socket_suffix = ".network";

struct Limits {
  static constexpr std::size_t request_bytes = 8192;
  static constexpr std::size_t reply_bytes = recording::Limits::page_bytes + 32768;
  static constexpr std::size_t certificate_bytes = 4096;
  static constexpr std::size_t targets = 16;
  static constexpr std::size_t target_bytes = 259;
  static constexpr std::size_t arguments = 80;
  static constexpr std::size_t processes = 16;
  static constexpr std::size_t peers = 16;
};

enum class Operation : Byte { status, capture_start, capture_stop, redirect_start, redirect_stop, ca_certificate, ca_install, ca_uninstall, ca_rotate, recording };
enum class Result : Byte { ok, disabled, authorization_required, busy, failed, cleanup_required };
enum class CaptureState : Byte { disabled, idle, live, offline };
enum class RedirectState : Byte { disabled, idle, starting, active, stopping, cleanup_required };
enum class TrustState : Byte { absent, installed, stale };

struct Request {
  Operation operation = Operation::status;
  std::array<std::string_view, Limits::targets> targets{};
  std::size_t target_count = 0;
  std::optional<recording::Request> recording;
  std::array<std::uint32_t, Limits::processes> processes{};
  std::size_t process_count = 0;
  redirect::Direction direction = redirect::Direction::outbound;
};

struct Status {
  CaptureState capture = CaptureState::disabled;
  RedirectState redirect = RedirectState::disabled;
  TrustState trust = TrustState::absent;
  bool proxy = false;
  bool transparent_tls = false;
  bool tls_accepting = false;
  bool interception = false;
  bool administration = false;
  std::uint16_t port = 0;
  std::uint64_t capture_session = 0;
  std::uint32_t interfaces = 0;
  std::uint32_t interface_errors = 0;
};

struct Reply {
  Result result = Result::ok;
  Status status{};
  std::string_view message;
  std::string_view fingerprint_sha1;
  std::string_view fingerprint_sha256;
  std::span<const Byte> certificate;
  std::array<std::string_view, Limits::arguments> authorization{};
  std::size_t argument_count = 0;
  std::span<const Byte> recording;
};

class Protocol {
public:
  static constexpr std::uint32_t magic = 0x31434e54;
  static constexpr std::uint32_t recording_magic = 0x32434e54;
  static constexpr std::uint32_t selection_magic = 0x33434e54;
  static constexpr std::uint32_t direction_magic = 0x34434e54;
  static constexpr std::size_t prefix_bytes = sizeof(std::uint32_t);

  static Request action(std::string_view name) {
    constexpr std::array names{"status", "capture.start", "capture.stop", "redirect.start", "redirect.stop", "ca.certificate", "ca.install", "ca.uninstall", "ca.rotate"};
    const auto found = std::ranges::find(names, name);
    if (found != names.end()) { return {.operation = static_cast<Operation>(found - names.begin())}; }
    constexpr std::array recordings{"recording.start", "recording.query", "recording.stop", "recording.remove", "recording.export", "recording.list"};
    const auto recording = std::ranges::find(recordings, name);
    if (recording != recordings.end()) { return {.operation = Operation::recording, .recording = recording::Request{.operation = static_cast<recording::Operation>(recording - recordings.begin())}}; }
    throw EncodingError{"Unknown network control action"};
  }

  static std::array<Byte, prefix_bytes> prefix(std::size_t size) {
    if (size == 0 || size > Limits::reply_bytes) { throw EncodingError{"Invalid network control frame size"}; }
    std::array<Byte, prefix_bytes> output;
    plugins::FrameWriter writer{output};
    writer.integer(static_cast<std::uint32_t>(size));
    return output;
  }

  static std::span<const Byte> encode(std::span<Byte> output, const Request &request) {
    validate(request);
    plugins::FrameWriter writer{output.first(std::min(output.size(), Limits::request_bytes))};
    writer.integer(request.direction != redirect::Direction::outbound ? direction_magic : request.process_count != 0 ? selection_magic : request.recording ? recording_magic : magic);
    writer.tag(request.operation);
    writer.integer(static_cast<Byte>(request.target_count));
    for (const auto target : std::span{request.targets}.first(request.target_count)) { writer.text(target); }
    if (request.recording) { recording::Protocol::write(writer, *request.recording); }
    if (request.process_count != 0 || request.direction != redirect::Direction::outbound) {
      writer.integer(static_cast<Byte>(request.process_count));
      for (const auto pid : std::span{request.processes}.first(request.process_count)) { writer.integer(pid); }
    }
    if (request.direction != redirect::Direction::outbound) { writer.tag(request.direction); }
    return writer.finish();
  }

  static Request request(std::span<const Byte> bytes) {
    if (bytes.size() > Limits::request_bytes) { throw EncodingError{"Network control request exceeds its bound"}; }
    plugins::FrameReader reader{bytes};
    const auto version = reader.integer<std::uint32_t>();
    if (version != magic && version != recording_magic && version != selection_magic && version != direction_magic) { throw EncodingError{"Incompatible network control protocol"}; }
    Request request;
    request.operation = reader.tag(version != magic ? Operation::recording : Operation::ca_rotate);
    request.target_count = reader.integer<Byte>();
    if (request.target_count > request.targets.size()) { throw EncodingError{"Too many redirect targets"}; }
    for (auto &target : std::span{request.targets}.first(request.target_count)) { target = reader.text(); }
    if (request.operation == Operation::recording) { request.recording = recording::Protocol::read(reader); }
    if (version == selection_magic || version == direction_magic) {
      request.process_count = reader.integer<Byte>();
      if (request.process_count > request.processes.size()) { throw EncodingError{"Too many selected processes"}; }
      for (auto &pid : std::span{request.processes}.first(request.process_count)) { pid = reader.integer<std::uint32_t>(); }
    }
    if (version == direction_magic) { request.direction = reader.tag(redirect::Direction::both); }
    reader.finish();
    validate(request);
    return request;
  }

  static std::span<const Byte> encode(std::span<Byte> output, const Reply &reply) {
    validate(reply);
    plugins::FrameWriter writer{output.first(std::min(output.size(), Limits::reply_bytes))};
    writer.integer(reply.recording.empty() ? magic : recording_magic);
    writer.tag(reply.result);
    writer.tag(reply.status.capture);
    writer.tag(reply.status.redirect);
    writer.tag(reply.status.trust);
    writer.boolean(reply.status.proxy);
    writer.boolean(reply.status.transparent_tls);
    writer.boolean(reply.status.tls_accepting);
    writer.boolean(reply.status.interception);
    writer.boolean(reply.status.administration);
    writer.integer(reply.status.port);
    writer.integer(reply.status.capture_session);
    writer.integer(reply.status.interfaces);
    writer.integer(reply.status.interface_errors);
    writer.text(reply.message);
    writer.text(reply.fingerprint_sha1);
    writer.text(reply.fingerprint_sha256);
    writer.bytes(reply.certificate);
    writer.integer(static_cast<Byte>(reply.argument_count));
    for (const auto argument : std::span{reply.authorization}.first(reply.argument_count)) { writer.text(argument); }
    if (!reply.recording.empty()) { writer.bytes(reply.recording); }
    return writer.finish();
  }

  static Reply reply(std::span<const Byte> bytes) {
    if (bytes.size() > Limits::reply_bytes) { throw EncodingError{"Network control reply exceeds its bound"}; }
    plugins::FrameReader reader{bytes};
    const auto version = reader.integer<std::uint32_t>();
    if (version != magic && version != recording_magic) { throw EncodingError{"Incompatible network control protocol"}; }
    Reply reply;
    reply.result = reader.tag(Result::cleanup_required);
    reply.status.capture = reader.tag(CaptureState::offline);
    reply.status.redirect = reader.tag(RedirectState::cleanup_required);
    reply.status.trust = reader.tag(TrustState::stale);
    reply.status.proxy = reader.boolean();
    reply.status.transparent_tls = reader.boolean();
    reply.status.tls_accepting = reader.boolean();
    reply.status.interception = reader.boolean();
    reply.status.administration = reader.boolean();
    reply.status.port = reader.integer<std::uint16_t>();
    reply.status.capture_session = reader.integer<std::uint64_t>();
    reply.status.interfaces = reader.integer<std::uint32_t>();
    reply.status.interface_errors = reader.integer<std::uint32_t>();
    reply.message = reader.text();
    reply.fingerprint_sha1 = reader.text();
    reply.fingerprint_sha256 = reader.text();
    reply.certificate = reader.bytes();
    reply.argument_count = reader.integer<Byte>();
    if (reply.argument_count > reply.authorization.size()) { throw EncodingError{"Too many authorization arguments"}; }
    for (auto &argument : std::span{reply.authorization}.first(reply.argument_count)) { argument = reader.text(); }
    if (version == recording_magic) { reply.recording = reader.bytes(); }
    reader.finish();
    validate(reply);
    return reply;
  }

private:
  static void validate(const Request &request) {
    if ((!redirect::allowsIncoming(request.direction) && !redirect::allowsOutgoing(request.direction)) || (request.direction != redirect::Direction::outbound && request.operation != Operation::redirect_start) || (redirect::allowsIncoming(request.direction) && request.process_count != 0)) { throw EncodingError{"Incoming redirect selects local services by account; process selection is outbound only"}; }
    if (request.process_count > request.processes.size() || (request.process_count != 0 && request.operation != Operation::redirect_start)) { throw EncodingError{"Processes are only valid for redirect selection"}; }
    const auto processes = std::span{request.processes}.first(request.process_count);
    for (std::size_t index = 0; index < processes.size(); ++index) {
      if (processes[index] == 0 || processes[index] > INT32_MAX || std::ranges::find(processes.first(index), processes[index]) != processes.first(index).end()) { throw EncodingError{"Invalid or duplicate selected process"}; }
    }
    if ((request.operation == Operation::recording) != request.recording.has_value()) { throw EncodingError{"Recording operation requires a recording request"}; }
    if (request.target_count > request.targets.size() || (request.operation == Operation::redirect_start ? request.target_count == 0 : request.target_count != 0)) {
      throw EncodingError{"Redirect start requires targets; other operations accept none"};
    }
    for (const auto target : std::span{request.targets}.first(request.target_count)) {
      if (target.empty() || target.size() > Limits::target_bytes || target.find_first_of("\r\n\0", 0, 3) != std::string_view::npos) {
        throw EncodingError{"Invalid redirect target"};
      }
    }
  }

  static void validate(const Reply &reply) {
    if (reply.recording.size() > recording::Limits::page_bytes) { throw EncodingError{"Recording reply exceeds its bound"}; }
    if (reply.message.size() > 1024 || reply.certificate.size() > Limits::certificate_bytes || reply.argument_count > reply.authorization.size() || (!reply.fingerprint_sha1.empty() && reply.fingerprint_sha1.size() != 40) || (!reply.fingerprint_sha256.empty() && reply.fingerprint_sha256.size() != 64)) {
      throw EncodingError{"Invalid network control reply"};
    }
    for (const auto argument : std::span{reply.authorization}.first(reply.argument_count)) {
      if (argument.empty() || argument.size() > 4096 || argument.contains('\0')) { throw EncodingError{"Invalid authorization argument"}; }
    }
  }
};

}
