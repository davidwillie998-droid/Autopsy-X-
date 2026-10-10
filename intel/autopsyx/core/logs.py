"""Structured JSON logging. One line per event, machine-parseable."""
from __future__ import annotations

import json
import logging
import time


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        out = {"ts": int(record.created * 1000), "level": record.levelname, "logger": record.name,
               "msg": record.getMessage()}
        extra = getattr(record, "fields", None)
        if isinstance(extra, dict):
            out.update(extra)
        if record.exc_info:
            out["exc"] = self.formatException(record.exc_info)
        return json.dumps(out, default=str)


def configure(level: int = logging.INFO) -> None:
    h = logging.StreamHandler()
    h.setFormatter(JsonFormatter())
    root = logging.getLogger("autopsyx")
    root.handlers[:] = [h]
    root.setLevel(level)
    root.propagate = False


def event(logger: logging.Logger, msg: str, **fields) -> None:
    logger.info(msg, extra={"fields": fields})


def timed(logger: logging.Logger, stage: str):
    """Context manager logging a stage's wall time."""
    class _T:
        def __enter__(self):
            self.t = time.perf_counter()
            return self

        def __exit__(self, *exc):
            event(logger, "stage_done", stage=stage, ms=round((time.perf_counter() - self.t) * 1000, 2))
            return False
    return _T()
