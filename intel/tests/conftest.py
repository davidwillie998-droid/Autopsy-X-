import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from autopsyx.core.config import Config  # noqa: E402
from autopsyx.pipeline import scan  # noqa: E402
from autopsyx.sim import generator  # noqa: E402


@pytest.fixture(scope="session")
def cfg():
    return Config.load()


@pytest.fixture(scope="session")
def store():
    return generator.build_store()


@pytest.fixture(scope="session")
def end_ts():
    return generator.end_ts()


@pytest.fixture(scope="session")
def result(store, cfg, end_ts):
    return scan(store.view(end_ts), cfg)


def key(addr: str) -> str:
    return f"solana:{addr}"
