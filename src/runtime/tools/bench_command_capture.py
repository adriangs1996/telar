#!/usr/bin/env python3
"""Alternate two builds of command-capture-probe: the scan of signed shell integration marks.

The probe runs command cycles as telar's zsh integration prints them, with marks signed by
the pane's token, through CommandZones and CommandBlocks as a pane's read does, and through
CommandTracker as PaneObserver does. Each sample is the probe's own timer around the cycles,
in ns per cycle; the digest of the marks, blocks and captured commands must match.

Build each variant in its own Release directory with

    tools/cpp configure release -B <dir>
    tools/cpp build release -B <dir> -- --target command-capture-probe

and pass the two trees. The host gate of tools/benchmark_host.py discards the whole
series when another build runs or the load is too high, so start it on a quiet host.
`command-capture-probe --describe <case>` shows what one cycle of a case reaches.
"""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from bench_terminal_media_feed import main

if __name__ == '__main__':
    main('command-capture-probe', __doc__)
