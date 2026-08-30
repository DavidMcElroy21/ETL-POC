"""A thin wrapper over Dagster Pipes.

The ingest scripts run in their own virtualenv, which does not (and must not)
contain Dagster. `dagster-pipes` is the zero-dependency client half of the
protocol: it lets this process stream logs and report asset materializations
back to the orchestrator over a side channel.

The wrapper exists so the same scripts stay usable standalone. Outside a Dagster
run, `open_dagster_pipes` hands back a mock that silently swallows everything --
fine for the orchestrator, useless when you are debugging a connection by hand.
Here, standalone falls back to printing.
"""

from __future__ import annotations

import warnings
from collections.abc import Iterator
from contextlib import contextmanager
from typing import Any

from dagster_pipes import (
    DagsterPipesWarning,
    PipesEnvVarParamsLoader,
    open_dagster_pipes,
)


class PipesReporter:
    """Reports progress to Dagster when orchestrated, to stdout when not."""

    def __init__(
        self,
        context: Any,
        *,
        asset_key_prefix: str,
        orchestrated: bool,
        default_streams: list[str],
    ) -> None:
        self._context = context
        self._prefix = asset_key_prefix
        self._orchestrated = orchestrated
        self._default_streams = default_streams

    # -- construction -------------------------------------------------------

    @classmethod
    @contextmanager
    def open(
        cls,
        *,
        asset_key_prefix: str,
        default_streams: list[str] | None = None,
    ) -> Iterator[PipesReporter]:
        orchestrated = PipesEnvVarParamsLoader().is_dagster_pipes_process()

        if not orchestrated:
            # Suppress the "not launched by Dagster" warning: running these
            # scripts by hand is a supported, documented workflow.
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", DagsterPipesWarning)
                context = open_dagster_pipes()
            yield cls(
                context,
                asset_key_prefix=asset_key_prefix,
                orchestrated=False,
                default_streams=default_streams or [],
            )
            return

        with open_dagster_pipes() as context:
            yield cls(
                context,
                asset_key_prefix=asset_key_prefix,
                orchestrated=True,
                default_streams=default_streams or [],
            )

    # -- reporting ----------------------------------------------------------

    def get_extra(self, key: str, default: Any = None) -> Any:
        """Read a value Dagster passed through Pipes extras.

        Falls back to `default` when running standalone, or when the
        orchestrator did not supply the key.
        """
        if not self._orchestrated:
            return default
        value = self._context.get_extra(key)
        return default if value is None else value

    @property
    def streams(self) -> list[str]:
        """Stream names to sync.

        Dagster passes the selection through Pipes extras, so materializing a
        subset of assets in the UI syncs only those streams. Standalone runs
        fall back to whatever was passed on the command line.
        """
        selected = self.get_extra("streams")
        return list(selected) if selected else list(self._default_streams)

    def log(self, message: str) -> None:
        if self._orchestrated:
            self._context.log.info(message)
        else:
            print(message, flush=True)

    def report_stream(self, *, stream_name: str, metadata: dict[str, Any]) -> None:
        """Record that one stream finished loading."""
        if self._orchestrated:
            self._context.report_asset_materialization(
                asset_key=f"{self._prefix}/{stream_name}",
                metadata={
                    key: _as_pipes_metadata(value) for key, value in metadata.items()
                },
            )
        else:
            print(f"materialized {self._prefix}/{stream_name}: {metadata}", flush=True)


def _as_pipes_metadata(value: Any) -> Any:
    """Give Dagster a usable type hint for each metadata value.

    Without this everything renders as a JSON blob; with it, row counts get the
    numeric treatment in the UI and file lists stay readable.
    """
    if isinstance(value, bool):
        return {"raw_value": value, "type": "bool"}
    if isinstance(value, int):
        return {"raw_value": value, "type": "int"}
    if isinstance(value, float):
        return {"raw_value": value, "type": "float"}
    if isinstance(value, (list, tuple)):
        return {"raw_value": "\n".join(str(item) for item in value), "type": "md"}
    return {"raw_value": str(value), "type": "text"}
