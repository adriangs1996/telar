#!/usr/bin/env python3
"""Prepare a macOS GUI timeline without editing production sources.

Configure an isolated Release GUI with '-DCMAKE_CXX_FLAGS=-ivfsoverlay OUTPUT/overlay.json'.
The generated header reuses the bounded runtime scope recorder. Set
TGB_GUI_PHASE_TRACE to an unused output prefix. Shutdown writes PREFIX.PID.jsonl.
Clocks are bracketed against CACurrentMediaTime at startup and shutdown.
These instrumented builds diagnose elapsed stages, not performance acceptance.
"""
import argparse
import hashlib
import json
from pathlib import Path

from prepare_runtime_scope_overlay import replace_once

ROOT = Path(__file__).resolve().parents[1]


def prepare(output):
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    inputs = {}
    roots = []

    def read(relative):
        path = ROOT / relative
        inputs[str(path)] = hashlib.sha256(path.read_bytes()).hexdigest()
        return path.read_text()

    def add(relative, source):
        target = output / Path(relative).name
        target.write_text('#include "' + str(output / 'gui_phase_trace.hpp') + '"\n' + source)
        roots.append(dict(type='file', name=str(ROOT / relative), **{'external-contents': str(target)}))

    header = read('tools/macos_runtime_scope_trace.hpp')
    header = replace_once(header, '#include <array>', '#include <array>\n#include <cmath>\n#include <dlfcn.h>')
    header = header.replace('TELAR_RUNTIME_PHASE_TRACE', 'TGB_GUI_PHASE_TRACE')
    header = replace_once(header, '  ~Buffer() {\n', '''  Buffer() { calibrate(); }

  void calibrate() {
    if (prefix == nullptr) {
      return;
    }

    const auto clock = reinterpret_cast<double (*)()>(dlsym(RTLD_DEFAULT, "CACurrentMediaTime"));
    std::uint64_t thread = 0;
    if (clock == nullptr || pthread_threadid_np(nullptr, &thread) != 0) {
      std::_Exit(75);
    }

    const auto before = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    const auto native = static_cast<std::uint64_t>(std::llround(clock() * 1e9));
    const auto after = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    const auto index = count.fetch_add(1, std::memory_order_relaxed);
    if (index < capacity) {
      records[index] = {"trace.clock", before, after, thread, 0, native, 0};
    }
  }

  ~Buffer() {
    calibrate();
''')
    (output / 'gui_phase_trace.hpp').write_text(header)

    path = 'src/gui-cpp/qt/application.cpp'
    source = read(path)
    source = replace_once(source, '  WindowImages::forWindow(window);\n', '''  WindowImages::forWindow(window);
  connect(&window, &QQuickWindow::beforeFrameBegin, this, [&window] {
    TELAR_PHASE_TRACE("qt.frame_begin", &window, 0, 0);
  }, Qt::DirectConnection);
  connect(&window, &QQuickWindow::beforeSynchronizing, this, [&window] {
    TELAR_PHASE_TRACE("qt.before_sync", &window, 0, 0);
  }, Qt::DirectConnection);
  connect(&window, &QQuickWindow::afterSynchronizing, this, [&window] {
    TELAR_PHASE_TRACE("qt.after_sync", &window, 0, 0);
  }, Qt::DirectConnection);
  connect(&window, &QQuickWindow::beforeRendering, this, [&window] {
    TELAR_PHASE_TRACE("qt.before_render", &window, 0, 0);
  }, Qt::DirectConnection);
  connect(&window, &QQuickWindow::afterRendering, this, [&window] {
    TELAR_PHASE_TRACE("qt.after_render", &window, 0, 0);
  }, Qt::DirectConnection);
  connect(&window, &QQuickWindow::afterFrameEnd, this, [&window] {
    TELAR_PHASE_TRACE("qt.frame_end", &window, 0, 0);
  }, Qt::DirectConnection);
''')
    source = replace_once(source, '    return frame_pacer_->defer(std::span{panes}.first(count));', '''    const bool deferred = frame_pacer_->defer(std::span{panes}.first(count));
    TELAR_PHASE_TRACE("pacer.decision", this, deferred, count);

    return deferred;''')
    for signature, name in [('void Application::prepareFrame(PresentedFrame &frame)', 'application.prepare'),
                            ('void Application::prepareTerminalFrames(PresentedFrame &frame)', 'application.prepared'),
                            ('void Application::refreshPanes()', 'application.refresh_panes'),
                            ('bool Application::executeNavigation(Action action, const QString &target)', 'application.navigate')]:
        anchor = signature + ' {\n'
        source = replace_once(source, anchor, anchor + f'  TELAR_PHASE_TRACE("{name}", this, 0, 0);\n')
    source = replace_once(source, '    const auto change = client.session.consume(byteView({payload.data(), static_cast<std::size_t>(payload.size())}), handler);', '''    const auto change = client.session.consume(byteView({payload.data(), static_cast<std::size_t>(payload.size())}), handler);
    const auto *trace_pane = change == Change::terminal ? client.session.findPane(client.session.changedPane()) : nullptr;
    TELAR_PHASE_TRACE(trace_pane != nullptr ? "frame.dispatch" : "message.apply", this,
                      trace_pane != nullptr ? trace_pane->id : 0,
                      trace_pane != nullptr ? trace_pane->screen.frameId() : 0);''')
    add(path, source)

    path = 'src/gui-cpp/qt/terminal_item.cpp'
    source = read(path)
    source = replace_once(source, '  CellSelection selection;\n', '''  TELAR_PHASE_TRACE("terminal.paint", this, current->id, current->screen.frameId());
  CellSelection selection;
''')
    source = replace_once(source, 'void TerminalItem::keyPressEvent(QKeyEvent *event) {\n', '''void TerminalItem::keyPressEvent(QKeyEvent *event) {
  TELAR_PHASE_TRACE("terminal.key", this, pane_id_, 0);
''')
    add(path, source)

    path = 'src/gui-cpp/qt/runtime_connection.cpp'
    source = read(path)
    source = replace_once(source, 'void RuntimeConnection::read() {\n', '''void RuntimeConnection::read() {
  TELAR_PHASE_TRACE("socket.read", this, 0, 0);
''')
    for signature, name in [('void RuntimeConnection::consume(std::span<const Byte> payload)', 'socket.consume'),
                            ('void RuntimeConnection::write(std::span<const Byte> payload)', 'socket.write')]:
        anchor = signature + ' {\n'
        source = replace_once(source, anchor, anchor + f'  TELAR_PHASE_TRACE("{name}", this, static_cast<std::uint64_t>(payload.empty() ? 0 : payload.front()), payload.size());\n')
    add(path, source)

    overlay = output / 'overlay.json'
    overlay.write_text(json.dumps(dict(version=0, **{'use-external-names': False}, roots=roots), indent=2) + '\n')
    generated = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in output.iterdir()}
    (output / 'manifest.json').write_text(json.dumps(dict(scope=__doc__, inputs=inputs, generated=generated), indent=2) + '\n')
    return overlay


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    print(prepare(args.output))


if __name__ == '__main__':
    main()
