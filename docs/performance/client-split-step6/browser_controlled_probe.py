import sys
from pathlib import Path
import shlex, subprocess
root = Path(sys.argv.pop(1))
sys.path.insert(0, str(root/'tools'))
import verify_terminal_browser as verifier
original = verifier.launch_ghostty

def launch(directory, wrapper):
    text = wrapper.read_text()
    prefix, command = text.rsplit('\nexec ',1)
    args = shlex.split(command)
    args.insert(1, '--no-config')
    wrapper.write_text(prefix+'\nexec '+shlex.join(args)+'\n')
    return original(directory, wrapper)

verifier.launch_ghostty = launch
import inspect
exec(inspect.getsource(verifier.inject_ghostty_input).replace('x 1200 y 500', 'x 600 y 250'), verifier.__dict__)
raise SystemExit(verifier.main())
