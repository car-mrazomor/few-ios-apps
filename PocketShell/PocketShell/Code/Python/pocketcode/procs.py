"""subprocess / os.system / os.popen for iOS: commands run in-process through PocketCode's shell.

iOS doesn't allow starting real processes, so a "process" here is a PocketCode shell command (python, pip, git, ls,
grep, sh scripts...) run in a child shell with its own cwd/variables, with stdin/stdout/stderr wired up like
subprocess would. Anything else raises FileNotFoundError, like a missing program does.
"""

import io
import os
import shlex
import shutil
import subprocess
import sys

_original_which = shutil.which
PYTHON_NAMES = ("python", "python3", "python3.13")


def _program_name(program):
    name = os.path.basename(os.fspath(program))
    return "python" if name in PYTHON_NAMES or os.fspath(program) == sys.executable else name


def _command_exists(name, path_hint):
    from . import shell

    return name in shell.COMMANDS or hasattr(shell.SHELL, "builtin_" + name) or os.path.isfile(path_hint)


def _run(command_line, stdin_text, stdout_target, stderr_target, cwd, env):
    """Runs command_line in a child shell. Targets are file-like objects (or None = inherit)."""
    from . import sh, shell

    child = sh.Shell(shell.run_command)
    child.variables = dict(shell.SHELL.variables)
    child.functions = dict(shell.SHELL.functions)

    saved_streams = (sys.stdin, sys.stdout, sys.stderr)
    saved_cwd = os.getcwd()
    saved_env = dict(os.environ)
    try:
        if cwd is not None:
            os.chdir(os.fspath(cwd))
        if env is not None:
            os.environ.clear()
            os.environ.update({k: v for k, v in env.items() if isinstance(v, str)})
        if stdin_text is not None:
            sys.stdin = io.StringIO(stdin_text)
        if stdout_target is not None:
            sys.stdout = stdout_target
        if stderr_target is not None:
            sys.stderr = stdout_target if stderr_target is subprocess.STDOUT else stderr_target
        try:
            return child.run(command_line)
        except sh.ParseError as error:
            print(f"sh: {error}", file=sys.stderr)
            return 2
    finally:
        sys.stdin, sys.stdout, sys.stderr = saved_streams
        if os.path.isdir(saved_cwd):
            os.chdir(saved_cwd)
        if env is not None:
            os.environ.clear()
            os.environ.update(saved_env)


class _Discard(io.StringIO):
    pass


class EmulatedPopen(subprocess.Popen):
    """Runs the command when its input is known (immediately, or at communicate() when stdin=PIPE)."""

    def __init__(self, args, bufsize=-1, executable=None, stdin=None, stdout=None, stderr=None, preexec_fn=None,
                 close_fds=True, shell=False, cwd=None, env=None, universal_newlines=None, startupinfo=None,
                 creationflags=0, restore_signals=True, start_new_session=False, pass_fds=(), *, user=None,
                 group=None, extra_groups=None, encoding=None, errors=None, text=None, umask=-1, pipesize=-1,
                 process_group=None):
        self.args = args
        self.pid = 0
        self.returncode = None
        self.text_mode = bool(text or universal_newlines or encoding or errors)
        self.encoding = encoding or "utf-8"
        self.errors = errors or "replace"
        self._stdin_mode, self._stdout_mode, self._stderr_mode = stdin, stdout, stderr
        self._cwd, self._env = cwd, env
        self.stdin = self.stdout = self.stderr = None
        self._input = None

        if isinstance(args, (str, bytes, os.PathLike)) and (shell or not isinstance(args, (list, tuple))):
            command_line = os.fsdecode(args) if not isinstance(args, str) else args
            if not shell:
                program = command_line
                command_line = shlex.quote(command_line)
            else:
                program = None
        else:
            argv = [os.fsdecode(a) if isinstance(a, bytes) else os.fspath(a) for a in args]
            if executable:
                argv[0] = os.fspath(executable)
            program = argv[0]
            argv[0] = _program_name(argv[0])
            command_line = shlex.join(argv)
        if program is not None and not _command_exists(_program_name(program), program):
            raise FileNotFoundError(2, "No such file or directory", os.fspath(program))
        self._command_line = command_line

        if stdin == subprocess.PIPE:
            self.stdin = _InputCollector(self)
        else:
            self._execute(self._read_stdin_source(stdin))

    # Running

    def _read_stdin_source(self, stdin):
        if stdin is None:
            return None
        if stdin == subprocess.DEVNULL:
            return ""
        if hasattr(stdin, "read"):
            data = stdin.read()
            return data.decode(self.encoding, self.errors) if isinstance(data, bytes) else data
        if isinstance(stdin, int):
            with os.fdopen(os.dup(stdin), "r") as f:
                return f.read()
        return None

    def _target(self, mode):
        if mode is None:
            return None, None
        if mode in (subprocess.PIPE,):
            buffer = io.StringIO()
            return buffer, buffer
        if mode == subprocess.DEVNULL:
            return _Discard(), None
        if mode == subprocess.STDOUT:
            return subprocess.STDOUT, None
        if hasattr(mode, "write"):
            return _TextAdapter(mode), None
        if isinstance(mode, int):
            return _TextAdapter(os.fdopen(os.dup(mode), "w")), None
        return None, None

    def _execute(self, stdin_text):
        out_target, out_buffer = self._target(self._stdout_mode)
        err_target, err_buffer = self._target(self._stderr_mode)
        self.returncode = _run(self._command_line, stdin_text, out_target, err_target, self._cwd, self._env)
        self._stdout_data = self._convert(out_buffer.getvalue()) if out_buffer is not None else None
        self._stderr_data = self._convert(err_buffer.getvalue()) if err_buffer is not None else None
        self.stdout = self._stream(self._stdout_data) if out_buffer is not None else None
        self.stderr = self._stream(self._stderr_data) if err_buffer is not None else None

    def _convert(self, text):
        return text if self.text_mode else text.encode(self.encoding, self.errors)

    def _stream(self, data):
        return io.StringIO(data) if self.text_mode else io.BytesIO(data)

    # Popen API

    def communicate(self, input=None, timeout=None):
        if self.returncode is None:
            pending = self._input if self._input is not None else ""
            if input is not None:
                pending += input.decode(self.encoding, self.errors) if isinstance(input, bytes) else input
            self._execute(pending)
        return getattr(self, "_stdout_data", None), getattr(self, "_stderr_data", None)

    def wait(self, timeout=None):
        if self.returncode is None:
            self.communicate()
        return self.returncode

    def poll(self):
        return self.returncode

    def send_signal(self, sig):
        pass

    def terminate(self):
        pass

    def kill(self):
        pass

    def __exit__(self, exc_type, value, traceback):
        self.wait()

    def __del__(self):
        pass


class _InputCollector:
    """proc.stdin when stdin=PIPE: buffers writes until communicate()/wait()."""

    def __init__(self, process):
        self.process = process
        process._input = ""

    def write(self, data):
        text = data.decode(self.process.encoding, self.process.errors) if isinstance(data, bytes) else data
        self.process._input += text
        return len(data)

    def flush(self):
        pass

    def close(self):
        pass

    @property
    def closed(self):
        return False


class _TextAdapter(io.TextIOBase):
    """Lets shell commands (which write str) write into a binary or text file object."""

    def __init__(self, target):
        self.target = target

    def write(self, text):
        try:
            self.target.write(text)
        except TypeError:
            self.target.write(text.encode())
        return len(text)

    def flush(self):
        getattr(self.target, "flush", lambda: None)()


def system(command):
    status = _run(command, None, None, None, None, None)
    return status << 8  # like a POSIX wait status


class _PopenFile(io.StringIO):
    def __init__(self, text, status):
        super().__init__(text)
        self._status = status

    def close(self):
        super().close()
        return None if self._status == 0 else self._status << 8


def popen(command, mode="r", buffering=-1):
    if "w" in mode:
        raise OSError("os.popen(..., 'w') isn't supported on iOS")
    buffer = io.StringIO()
    status = _run(command, None, buffer, None, None, None)
    return _PopenFile(buffer.getvalue(), status)


def which(cmd, mode=os.F_OK | os.X_OK, path=None):
    from . import shell

    name = _program_name(cmd)
    if name in shell.COMMANDS or hasattr(shell.SHELL, "builtin_" + name):
        return "/usr/bin/" + os.path.basename(os.fspath(cmd))
    return _original_which(cmd, mode, path)


def install():
    subprocess.Popen = EmulatedPopen
    os.system = system
    os.popen = popen
    shutil.which = which
    # Leave sys.executable alone: on iOS, CPython finds its compiled modules (app frameworks) relative to it.
    # Commands that use [sys.executable, ...] are recognized as python by _program_name.
    # Things that genuinely need a real process.
    for name in ("fork", "forkpty", "execv", "execve", "execvp", "execvpe", "spawnv", "spawnve", "posix_spawn",
                 "posix_spawnp"):
        if hasattr(os, name):
            setattr(os, name, _unsupported(name))


def _unsupported(name):
    def fail(*args, **kwargs):
        raise OSError(f"os.{name}() isn't available: iOS doesn't let apps start processes.")

    return fail
