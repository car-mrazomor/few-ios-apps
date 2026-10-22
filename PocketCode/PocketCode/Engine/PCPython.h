#ifndef PCPython_h
#define PCPython_h

#include <stdbool.h>

/// Output from Python: stream 1 = stdout, 2 = stderr. Text is UTF-8, not NUL-terminated.
typedef void (*pc_write_fn)(int stream, const char *text, long length);
/// Blocks until the user submits a line. Returns a malloc'd UTF-8 string (caller frees),
/// or NULL for EOF (Ctrl-D). Sets *interrupted for Ctrl-C.
typedef char *(*pc_readline_fn)(const char *prompt, bool *interrupted);
/// Notifications from Python to the app, e.g. ("open", "/path/file.py").
typedef void (*pc_event_fn)(const char *name, const char *payload);

/// Starts the interpreter on the calling thread, which becomes Python's main thread.
/// All other pc_* calls except pc_interrupt must happen on this same thread.
/// Returns NULL on success, or a malloc'd error message.
char *pc_initialize(const char *bundle_path, const char *documents_path, const char *support_path,
                    pc_write_fn write, pc_readline_fn readline, pc_event_fn event);

/// Runs one shell command line. Returns the command's exit status.
int pc_run_line(const char *line);

/// Calls pocketcode.shell.<function>(argument) and returns its str() result (malloc'd), or NULL on error.
char *pc_call(const char *function, const char *argument);

/// Raises KeyboardInterrupt in the running Python code. Safe to call from any thread.
void pc_interrupt(void);

#endif
