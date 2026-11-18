import json
from pathlib import Path
import shlex
import sys
import time


def emit(record):
    print(json.dumps(record), flush=True)


def main():
    marker = shlex.quote(str(Path(sys.argv[1])))
    command = ''
    delayed_reply_seconds = 0.15
    timed_out_reply_seconds = 2
    waiting_capture_seconds = 20
    preview_text_bytes = 600
    for line in sys.stdin:
        request = json.loads(line)
        operation = request.get('type')
        if operation == 'prompt':
            task = request.get('message', '')
            if 'fixture:waiting' in task:
                time.sleep(waiting_capture_seconds)
            if 'fixture:timeout' in task:
                time.sleep(timed_out_reply_seconds)
            if 'fixture:fail' in task:
                emit(dict(type='response', command='prompt', success=False))
                continue
            if 'fixture:delay' in task:
                time.sleep(delayed_reply_seconds)
            text = 'ALTERNATE_REVIEW' if 'fixture:alternate' in task else 'SUGGESTION_REVIEW'
            if 'fixture:long' in task:
                text = 'x' * preview_text_bytes
            command = 'printf ' + shlex.quote(text) + ' > ' + marker
            emit(dict(type='response', command='prompt', success=True))
            emit(dict(type='agent_settled'))
        elif operation == 'get_last_assistant_text':
            emit(dict(type='response', command=operation, success=True, data=dict(text=command)))


if __name__ == '__main__':
    main()
