"""Per-run cooperative cancellation; stale requests cannot stop the next run."""
import json
import os
from pathlib import Path
import signal
import threading
import subprocess


class Cancelled(BaseException):
    pass


_requested = False
_readers = set()
_lock = threading.Lock()


def check():
    if _requested:
        raise Cancelled()


def reader_started(process):
    with _lock:
        _readers.add(process)
        if _requested and process.poll() is None:
            process.terminate()


def reader_finished(process):
    with _lock:
        _readers.discard(process)


def cancel_readers():
    with _lock:
        readers = list(_readers)
        for process in readers:
            if process.poll() is None:
                process.terminate()
    for process in readers:
        try:
            process.wait(timeout=0.5)
        except subprocess.TimeoutExpired:
            process.kill()


def run_copy(arguments):
    """An owned copy helper must finish/exit before its private stage is removed."""
    process = subprocess.Popen(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        output, error = process.communicate()
        if process.returncode:
            raise subprocess.CalledProcessError(process.returncode, arguments, output, error)
    except BaseException:
        process.kill()
        process.communicate()
        raise


def configure(run_id, stop_file):
    if not run_id or not stop_file:
        return
    path = Path(stop_file)
    def stopped(_signum, _frame):
        global _requested
        _requested = True
        raise Cancelled()
    signal.signal(signal.SIGUSR1, stopped)
    def watch():
        while True:
            try:
                request = json.loads(path.read_text()) if not path.is_symlink() else {}
                if request.get('runID') == run_id:
                    os.kill(os.getpid(), signal.SIGUSR1)
                    return
            except (OSError, ValueError):
                pass
            threading.Event().wait(0.2)
    threading.Thread(target=watch, daemon=True).start()
