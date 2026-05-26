"""Outbound message queue — pure data structure."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "session")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _outbound_queue_toolchain import (
    OutboundMessageQueue,
)
::py::
