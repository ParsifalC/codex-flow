#!/usr/bin/env python3
"""Source-only macOS analysis preview. No installation or global process control."""
from __future__ import annotations
import argparse
import fcntl
import json
import os
from pathlib import Path
import plistlib
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = Path(__file__).resolve()
ANALYSIS = ROOT / 'scripts' / 'analysis.py'
_CHILDREN = {}


def atomic(path, data):
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix='.' + path.name)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(data, stream, ensure_ascii=False)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, str(path))
    finally:
        if os.path.exists(tmp): os.unlink(tmp)


def read(path):
    try:
        data = json.loads(path.read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError): return {}


def locked(state):
    try: fd = os.open(str(state / 'preview.lock'), os.O_RDWR)
    except OSError: return False
    try:
        try: fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: return True
        return False
    finally: os.close(fd)


def request(meta, command):
    try:
        port = meta['port']
        token = meta['token']
        if not isinstance(port, int) or not 0 < port < 65536 or not isinstance(token, str): return None
        with socket.create_connection(('127.0.0.1', port), timeout=.5) as client:
            client.sendall((json.dumps({'token': token, 'command': command}) + '\n').encode())
            data = b''
            while b'\n' not in data and len(data) < 16384:
                chunk = client.recv(4096)
                if not chunk: break
                data += chunk
            result = json.loads(data)
            return result if result.get('ok') is True else None
    except (OSError, ValueError, KeyError, TypeError): return None


def status(state):
    state = Path(state).expanduser().resolve()
    if not locked(state):
        child = _CHILDREN.pop(str(state), None)
        if child is not None:
            try: child.wait(timeout=1)
            except subprocess.TimeoutExpired: _CHILDREN[str(state)] = child
        last = read(state / 'preview-runtime.json')
        return {'running': False, 'state_dir': str(state), 'reason': last.get('reason')}
    response = request(read(state / 'preview-runtime.json'), 'status')
    return response or {'running': True, 'status': 'starting_or_stopping', 'state_dir': str(state)}


def stop(state):
    state = Path(state).expanduser().resolve()
    if not locked(state): return status(state)
    response = request(read(state / 'preview-runtime.json'), 'stop')
    if response is None:
        return dict(status(state), error='control_unavailable; no PID was signalled')
    for _ in range(150):
        if not locked(state): return status(state)
        time.sleep(.1)
    return dict(status(state), error='shutdown_timeout')


def prepare_state(state):
    if state.exists():
        if state.is_symlink() or not state.is_dir() or state.stat().st_uid != os.getuid():
            raise ValueError('state directory must be a directory owned by you')
        if any(state.iterdir()) and not (state / 'config.json').is_file() and not (state / 'preview.lock').is_file():
            raise ValueError('choose an empty private state directory')
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    state.chmod(0o700)


def ui_binary(args, state):
    if args.ui_binary:
        binary = Path(args.ui_binary).expanduser().resolve()
        if not binary.is_file() or not os.access(str(binary), os.X_OK): raise ValueError('UI binary is missing or not executable')
        return binary
    binary = ROOT / 'apps/macos-overlay/bin/FlowPilot'
    sources = list((ROOT / 'apps/macos-overlay/Sources').rglob('*.swift'))
    if not binary.exists() or any(p.stat().st_mtime > binary.stat().st_mtime for p in sources):
        env = dict(os.environ, CODEX_HOME=str(state / 'build-home'))
        with open(state / 'build.log', 'w') as log:
            os.chmod(str(state / 'build.log'), 0o600)
            result = subprocess.run(['bash', str(ROOT / 'apps/macos-overlay/build.sh')], env=env, stdout=log, stderr=log)
        if result.returncode: raise ValueError('native build failed; see private build.log')
    # A local bundle gives the preview its own app identity and keyboard menu.
    app = state / 'FlowPilot Analysis Preview.app' / 'Contents'
    executable = app / 'MacOS' / 'FlowPilotAnalysisPreview'
    executable.parent.mkdir(parents=True, exist_ok=True)
    # Replace the inode instead of overwriting a potentially mapped Mach-O.
    # The source signature belongs to its original bundle, not this preview.
    fd, temporary = tempfile.mkstemp(dir=str(executable.parent))
    os.close(fd)
    try:
        shutil.copy2(str(binary), temporary)
        os.replace(temporary, str(executable))
    finally:
        if os.path.exists(temporary): os.unlink(temporary)
    with (app / 'Info.plist').open('wb') as stream:
        plistlib.dump({'CFBundleExecutable': executable.name, 'CFBundleIdentifier': 'local.codexflow.analysis-preview', 'CFBundleName': 'FlowPilot Analysis Preview', 'CFBundlePackageType': 'APPL', 'NSHighResolutionCapable': True}, stream)
    signed = subprocess.run(['codesign', '--force', '--sign', '-', str(app.parent)], capture_output=True, text=True)
    if signed.returncode:
        raise ValueError('preview bundle signing failed: ' + signed.stderr.strip())
    return executable


def start(args):
    state = Path(args.state_dir).expanduser().absolute()
    prepare_state(state)
    state = state.resolve()
    fd = os.open(str(state / 'preview.lock'), os.O_CREAT | os.O_RDWR, 0o600)
    try:
        try: fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: return status(state)
        binary = ui_binary(args, state)
        config = read(state / 'config.json')
        transcript = args.transcript or config.get('transcript')
        session_id = args.session_id or config.get('session_id')
        if not transcript or not session_id: raise ValueError('--transcript and --session-id are required for a new preview')
        codex = args.codex_bin or config.get('codex_bin') or shutil.which('codex')
        codex = shutil.which(codex) if codex else None
        if not codex: raise ValueError('codex executable was not found')
        model = args.model or config.get('model') or 'gpt-5.6-luna'
        auth = args.auth_home or config.get('auth_home') or str(Path.home() / '.codex')
        command = [sys.executable, str(ANALYSIS), 'configure', '--state-dir', str(state), '--transcript', str(Path(transcript).expanduser().resolve()), '--session-id', session_id, '--model', model, '--codex-bin', codex, '--auth-home', str(Path(auth).expanduser().resolve())]
        configured = subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        if configured.returncode: raise ValueError('analysis configuration failed: ' + configured.stderr[-500:])
        atomic(state / 'preview-launch.json', {'state_dir': str(state), 'binary': str(binary), 'python': sys.executable, 'analysis': str(ANALYSIS), 'source_checkout': str(ROOT)})
        with open(state / 'preview.log', 'a') as log:
            os.chmod(str(state / 'preview.log'), 0o600)
            child = subprocess.Popen([sys.executable, str(SCRIPT), '_run', '--state-dir', str(state), '--lock-fd', str(fd)], stdin=subprocess.DEVNULL, stdout=log, stderr=log, pass_fds=(fd,), start_new_session=True)
    finally:
        os.close(fd)
    _CHILDREN[str(state)] = child
    for _ in range(100):
        if child.poll() is not None: raise ValueError('preview could not start: ' + str(read(state / 'preview-runtime.json').get('reason', 'see preview.log')))
        current = status(state)
        if current.get('ready'): return current
        time.sleep(.1)
    child.terminate()
    child.wait(timeout=15)
    raise ValueError('preview startup timed out')


def terminate(process):
    if process is None or process.poll() is not None: return
    process.terminate()
    try: process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def supervise(state, lock_fd):
    state = Path(state).resolve()
    config = read(state / 'preview-launch.json')
    worker = ui = None
    done = False
    reason = 'closed'
    def shutdown(_signal, _frame):
        nonlocal done
        done = True
    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    server = socket.socket()
    try:
        server.bind(('127.0.0.1', 0))
        server.listen(4)
        server.settimeout(.2)
        token = secrets.token_hex(32)
        home = state / 'ui-home'
        home.mkdir(exist_ok=True, mode=0o700)
        env = dict(os.environ, CODEX_HOME=str(home))
        with open(state / 'worker.log', 'a') as log:
            os.chmod(str(state / 'worker.log'), 0o600)
            worker = subprocess.Popen([config['python'], config['analysis'], 'watch', '--state-dir', str(state)], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=log, env=env)
            ui = subprocess.Popen([config['binary'], 'analysis-preview', '--state-dir', str(state), '--analysis-script', config['analysis'], '--python', config['python']], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=log, env=env)
            meta = {'schema_version': 1, 'pid': os.getpid(), 'worker_pid': worker.pid, 'ui_pid': ui.pid, 'state_dir': str(state), 'port': server.getsockname()[1], 'token': token}
            atomic(state / 'preview-runtime.json', meta)
            started = time.monotonic()
            while not done:
                if ui.poll() is not None:
                    reason = 'window_closed' if ui.returncode == 0 else 'ui_failed'
                    break
                if worker.poll() is not None:
                    reason = 'worker_exited'
                    break
                try: client, _ = server.accept()
                except socket.timeout: continue
                with client:
                    client.settimeout(.5)
                    try:
                        raw = b''
                        while b'\n' not in raw and len(raw) < 4096:
                            chunk = client.recv(4096)
                            if not chunk: break
                            raw += chunk
                        data = json.loads(raw)
                        valid = isinstance(data, dict) and secrets.compare_digest(str(data.get('token', '')), token)
                        command = data.get('command') if valid else None
                        answer = {'ok': False}
                        if command in ('status', 'stop'):
                            answer = {k: v for k, v in meta.items() if k not in ('token', 'port')}
                            answer.update(ok=True, running=True, ready=time.monotonic() - started > .3)
                            if command == 'stop': done = True
                        client.sendall((json.dumps(answer) + '\n').encode())
                    except (OSError, ValueError): pass
    except Exception as error:
        reason = 'startup_failed:' + type(error).__name__
    finally:
        server.close()
        terminate(worker)  # its signal handler reaps any in-flight model process
        terminate(ui)
        auth = state / 'private/codex-home/auth.json'
        try: auth.unlink()
        except FileNotFoundError: pass
        atomic(state / 'preview-runtime.json', {'running': False, 'reason': reason, 'state_dir': str(state)})
        os.close(lock_fd)
    return 0


def parser():
    p = argparse.ArgumentParser(description='Run the isolated conversation-analysis preview')
    commands = p.add_subparsers(dest='command', required=True)
    start_p = commands.add_parser('start')
    start_p.add_argument('--state-dir', required=True)
    for option in ('transcript', 'session-id', 'model', 'auth-home', 'codex-bin', 'ui-binary'):
        start_p.add_argument('--' + option)
    for name in ('status', 'stop', '_run'):
        child = commands.add_parser(name)
        child.add_argument('--state-dir', required=True)
        if name == '_run': child.add_argument('--lock-fd', type=int, required=True)
    return p


def main():
    args = parser().parse_args()
    try:
        if args.command == '_run': return supervise(args.state_dir, args.lock_fd)
        result = start(args) if args.command == 'start' else (stop(args.state_dir) if args.command == 'stop' else status(args.state_dir))
        print(json.dumps(result, ensure_ascii=False))
        return 0 if not result.get('error') else 2
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(json.dumps({'error': str(error)}, ensure_ascii=False), file=sys.stderr)
        return 2

if __name__ == '__main__': raise SystemExit(main())
