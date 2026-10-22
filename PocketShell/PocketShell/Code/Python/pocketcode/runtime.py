"""One-time interpreter setup, called from the app before the shell starts."""

import io
import os
import site
import sys

import _pocketcode

#: Where the user's projects live (Documents, visible in the Files app).
WORKSPACE = ""
#: Where `pip install` puts packages (Library/Application Support, hidden from Files).
USER_SITE = ""
#: Fake home directory for ~/.gitconfig and friends.
HOME = ""


class _Output(io.TextIOBase):
    def __init__(self, stream, name):
        self._stream = stream
        self._name = name

    @property
    def name(self):
        return self._name

    @property
    def encoding(self):
        return "utf-8"

    def writable(self):
        return True

    def isatty(self):
        return True

    def fileno(self):
        raise io.UnsupportedOperation("fileno")

    def write(self, text):
        if not isinstance(text, str):
            raise TypeError(f"write() argument must be str, not {type(text).__name__}")
        if text:
            _pocketcode.write(self._stream, text)
        return len(text)

    def flush(self):
        pass


class _Input(io.TextIOBase):
    """stdin backed by the terminal's line editor. input() writes its prompt to stdout, then calls readline()."""

    @property
    def name(self):
        return "<stdin>"

    @property
    def encoding(self):
        return "utf-8"

    def readable(self):
        return True

    def isatty(self):
        return True

    def fileno(self):
        raise io.UnsupportedOperation("fileno")

    def readline(self, size=-1):
        line = _pocketcode.readline("")
        return "" if line is None else line + "\n"

    def read(self, size=-1):
        if size is not None and size >= 0:
            return self.readline()[:size]
        chunks = []
        while line := self.readline():
            chunks.append(line)
        return "".join(chunks)


def setup(bundle_path, documents_path, support_path):
    global WORKSPACE, USER_SITE, HOME
    # On devices /var is a symlink to /private/var; os.getcwd() returns the resolved form, so match it.
    WORKSPACE = os.path.realpath(documents_path)
    USER_SITE = os.path.join(support_path, "site-packages")
    HOME = os.path.join(support_path, "home")
    os.makedirs(USER_SITE, exist_ok=True)
    os.makedirs(HOME, exist_ok=True)

    # pip's download cache goes in Library/Caches, which iOS clears when storage runs low.
    library = os.path.dirname(os.path.dirname(support_path))
    pip_cache = os.path.join(library, "Caches", "pip")
    old_pip_cache = os.path.join(HOME, ".cache", "pip")  # where versions before 0.2 put it
    if os.path.isdir(old_pip_cache):
        import shutil

        shutil.rmtree(old_pip_cache, ignore_errors=True)

    sys.stdout = sys.__stdout__ = _Output(1, "<stdout>")
    sys.stderr = sys.__stderr__ = _Output(2, "<stderr>")
    sys.stdin = sys.__stdin__ = _Input()

    # Bundled packages (pip, dulwich, certifi...) and the user's own installs.
    site.addsitedir(os.path.join(bundle_path, "app_packages"))
    site.addsitedir(USER_SITE)

    import certifi

    os.environ.update(
        {
            "HOME": HOME,
            "SSL_CERT_FILE": certifi.where(),
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "PIP_DISABLE_PIP_VERSION_CHECK": "1",
            "PIP_CACHE_DIR": pip_cache,
            "PIP_NO_COMPILE": "1",
            "PYTHONIOENCODING": "utf-8",
        }
    )

    # No real processes on iOS: subprocess / os.system run PocketCode's own commands in-process.
    from . import procs

    procs.install()

    os.chdir(WORKSPACE)
