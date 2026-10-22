#define PY_SSIZE_T_CLEAN
#include <Python/Python.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include "PCPython.h"

static pc_write_fn pc_write;
static pc_readline_fn pc_readline;
static pc_event_fn pc_event;
static pthread_t python_thread;
static PyObject *shell_module;

// MARK: - _pocketcode module (called from Python)

static PyObject *mod_write(PyObject *self, PyObject *args) {
    int stream;
    const char *text;
    Py_ssize_t length;
    if (!PyArg_ParseTuple(args, "is#", &stream, &text, &length)) return NULL;
    pc_write(stream, text, (long)length);
    Py_RETURN_NONE;
}

static PyObject *mod_readline(PyObject *self, PyObject *args) {
    const char *prompt = "";
    if (!PyArg_ParseTuple(args, "|s", &prompt)) return NULL;

    char *line;
    bool interrupted = false;
    // Release the GIL while waiting so Python threads keep running.
    Py_BEGIN_ALLOW_THREADS
    line = pc_readline(prompt, &interrupted);
    Py_END_ALLOW_THREADS

    if (interrupted) {
        free(line);
        PyErr_SetNone(PyExc_KeyboardInterrupt);
        return NULL;
    }
    if (line == NULL) Py_RETURN_NONE;  // EOF
    PyObject *result = PyUnicode_FromString(line);
    free(line);
    return result;
}

static PyObject *mod_event(PyObject *self, PyObject *args) {
    const char *name, *payload = "";
    if (!PyArg_ParseTuple(args, "s|s", &name, &payload)) return NULL;
    pc_event(name, payload);
    Py_RETURN_NONE;
}

static PyMethodDef module_methods[] = {
    {"write", mod_write, METH_VARARGS, "write(stream, text)"},
    {"readline", mod_readline, METH_VARARGS, "readline(prompt) -> str | None"},
    {"event", mod_event, METH_VARARGS, "event(name, payload)"},
    {NULL, NULL, 0, NULL},
};

static struct PyModuleDef module_def = {PyModuleDef_HEAD_INIT, "_pocketcode", NULL, -1, module_methods};

static PyObject *init_module(void) { return PyModule_Create(&module_def); }

// MARK: - Lifecycle

static char *copy_error(const char *prefix) {
    PyObject *type, *value, *traceback;
    PyErr_Fetch(&type, &value, &traceback);
    PyObject *text = value ? PyObject_Str(value) : NULL;
    const char *detail = text ? PyUnicode_AsUTF8(text) : "unknown error";
    size_t size = strlen(prefix) + strlen(detail) + 3;
    char *message = malloc(size);
    snprintf(message, size, "%s: %s", prefix, detail);
    Py_XDECREF(text);
    Py_XDECREF(type);
    Py_XDECREF(value);
    Py_XDECREF(traceback);
    return message;
}

static char *status_error(PyStatus status) {
    return strdup(status.err_msg ? status.err_msg : "Python initialization failed");
}

char *pc_initialize(const char *bundle_path, const char *documents_path, const char *support_path,
                    pc_write_fn write, pc_readline_fn readline, pc_event_fn event) {
    pc_write = write;
    pc_readline = readline;
    pc_event = event;
    python_thread = pthread_self();

    if (PyImport_AppendInittab("_pocketcode", init_module) == -1) return strdup("could not register _pocketcode");

    PyPreConfig preconfig;
    PyPreConfig_InitIsolatedConfig(&preconfig);
    preconfig.utf8_mode = 1;
    PyStatus status = Py_PreInitialize(&preconfig);
    if (PyStatus_Exception(status)) return status_error(status);

    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.buffered_stdio = 0;
    config.write_bytecode = 0;  // The app bundle is read-only.
    config.install_signal_handlers = 1;  // Needed for Ctrl-C (SIGINT -> KeyboardInterrupt).

    char home[4096];
    snprintf(home, sizeof home, "%s/python", bundle_path);
    status = PyConfig_SetBytesString(&config, &config.home, home);
    if (!PyStatus_Exception(status)) status = PyConfig_Read(&config);
    if (!PyStatus_Exception(status)) status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) return status_error(status);

    // Hand over to the Python side, which sets up paths, stdio and the shell.
    PyObject *sys_path = PySys_GetObject("path");  // borrowed
    char app_dir[4096];
    snprintf(app_dir, sizeof app_dir, "%s/app", bundle_path);
    PyObject *app_dir_obj = PyUnicode_FromString(app_dir);
    PyList_Insert(sys_path, 0, app_dir_obj);
    Py_DECREF(app_dir_obj);

    PyObject *runtime = PyImport_ImportModule("pocketcode.runtime");
    if (!runtime) return copy_error("import pocketcode.runtime");
    PyObject *result = PyObject_CallMethod(runtime, "setup", "sss", bundle_path, documents_path, support_path);
    Py_DECREF(runtime);
    if (!result) return copy_error("runtime.setup");
    Py_DECREF(result);

    shell_module = PyImport_ImportModule("pocketcode.shell");
    if (!shell_module) return copy_error("import pocketcode.shell");
    return NULL;
}

int pc_run_line(const char *line) {
    PyObject *result = PyObject_CallMethod(shell_module, "run_line", "s", line);
    if (!result) {
        PyErr_Print();
        return 1;
    }
    int code = (int)PyLong_AsLong(result);
    Py_DECREF(result);
    return code;
}

char *pc_call(const char *function, const char *argument) {
    PyObject *result = PyObject_CallMethod(shell_module, function, "s", argument);
    if (!result) {
        PyErr_Clear();
        return NULL;
    }
    PyObject *text = PyObject_Str(result);
    Py_DECREF(result);
    if (!text) {
        PyErr_Clear();
        return NULL;
    }
    char *copy = strdup(PyUnicode_AsUTF8(text));
    Py_DECREF(text);
    return copy;
}

void pc_interrupt(void) {
    // Sets Python's interrupt flag, then signals its thread so blocking calls like time.sleep() wake up too.
    PyErr_SetInterruptEx(SIGINT);
    pthread_kill(python_thread, SIGINT);
}
