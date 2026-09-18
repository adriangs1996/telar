import sys
from pathlib import Path
sys.path.insert(0, '/Users/adriangonzalez/sandbox/telar/tools')
import terminal_bench_fixture as fixture
fixture.PAYLOAD_BYTES = 64 * 1024 * 1024
fixture.LIFETIME_SECONDS = 180
fixture.Fixture(Path('/private/tmp/tgb-p2-stable-followup/raw/sustained-2-repeat-baseline/fixture')).run()
