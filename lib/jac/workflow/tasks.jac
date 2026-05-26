"""Task store — persist multi-step work under .jackal/tasks.json."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "workflow")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _tasks_toolchain import (
    TASKS_FILE,
    add_task,
    clear_tasks,
    format_task_line,
    format_tasks_list,
    generate_task_id,
    load_tasks,
    remove_task_by_id,
    remove_task_by_index,
    save_tasks,
    task_counts,
    tasks_path,
    update_tasks,
)
::py::
