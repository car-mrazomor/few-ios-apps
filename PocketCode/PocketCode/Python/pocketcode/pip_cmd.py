"""`pip`, run in-process. Installs go to the app's user site-packages."""

import importlib
import os
import sys

from . import runtime
from .colors import GRAY, YELLOW, paint

COMPILED_SUFFIXES = (".so", ".dylib", ".pyd")


def compiled_files():
    found = set()
    for root, _, files in os.walk(runtime.USER_SITE):
        found.update(os.path.join(root, f) for f in files if f.endswith(COMPILED_SUFFIXES))
    return found


def owning_package(path):
    relative = os.path.relpath(path, runtime.USER_SITE)
    return relative.split(os.sep)[0]


def run(args):
    from pip._internal.cli.main import main as pip_main
    from pip._internal.commands import install as install_command

    # pip assumes its process exits after installing, so it adds a permanent audit hook that flags every later
    # import. PocketCode keeps one interpreter alive for the whole session, so skip that hook.
    install_command._prevent_further_imports = lambda: None

    if not args:
        args = ["help"]

    before = compiled_files()
    if args[0] == "install" and not {"-t", "--target", "--user", "--prefix", "--root"} & set(args):
        # --target keeps installs in our writable folder; --upgrade lets reinstalls replace old copies.
        args = ["install", "--target", runtime.USER_SITE, "--upgrade", *args[1:]]
        if "-e" in args or "--editable" in args:
            print(paint(YELLOW, "Editable installs aren't supported; installing normally."))
            args = [a for a in args if a not in ("-e", "--editable")]

    saved_argv = sys.argv
    sys.argv = ["pip", *args]
    try:
        status = pip_main(args)
    finally:
        sys.argv = saved_argv
        importlib.invalidate_caches()

    new_compiled = compiled_files() - before
    if args[0] == "install" and new_compiled:
        packages = sorted({owning_package(p) for p in new_compiled})
        print(
            paint(YELLOW, "\n⚠ These packages contain compiled code, which iOS won't load: ")
            + ", ".join(packages)
            + paint(GRAY, "\n  Importing them will fail. Pure-Python packages work fine.")
        )
    return status
