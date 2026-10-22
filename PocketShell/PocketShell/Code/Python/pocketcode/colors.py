"""Gruvbox (dark) ANSI colors for shell output."""


def _rgb(hex_color):
    r, g, b = (int(hex_color[i : i + 2], 16) for i in (0, 2, 4))
    return f"\x1b[38;2;{r};{g};{b}m"


RESET = "\x1b[0m"
BOLD = "\x1b[1m"
RED = _rgb("fb4934")
GREEN = _rgb("b8bb26")
YELLOW = _rgb("fabd2f")
BLUE = _rgb("83a598")
PURPLE = _rgb("d3869b")
AQUA = _rgb("8ec07c")
ORANGE = _rgb("fe8019")
GRAY = _rgb("928374")
FG = _rgb("ebdbb2")


def paint(color, text):
    """Colors text, unless output is being captured or piped (like real tools do)."""
    import sys

    if not getattr(sys.stdout, "isatty", lambda: False)():
        return str(text)
    return f"{color}{text}{RESET}"
