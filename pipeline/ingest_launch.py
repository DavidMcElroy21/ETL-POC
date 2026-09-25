"""One call shape for launching an ingest module, wherever it runs.

The ingest half runs as a child process locally and as a separate container in
Azure. Those two Pipes clients do not take the same arguments -- one wants a
command line for an interpreter on the same filesystem, the other wants a
module name to run in a container it starts -- so the assets go through here
rather than each knowing which environment they are in.

Everything the two have in common lives in this one function: the module to
run, the extras Dagster passes down, and the results that come back.
"""

# Dagster resolves the `context` annotation on the asset functions at runtime,
# and this module is imported by them, so it inherits the same rule: no
# `from __future__ import annotations`.
from typing import Any, Optional, Sequence

from dagster import AssetExecutionContext, PipesSubprocessClient

from pipeline.config import INGEST_PYTHON, ingest_env


def launch_ingest(
    *,
    context: AssetExecutionContext,
    client: Any,
    module: str,
    extras: Optional[dict[str, Any]] = None,
    args: Optional[Sequence[str]] = None,
):
    """Run ``python -m <module>`` in the ingest environment and return results.

    `client` is whichever Pipes client the code location was configured with.
    The local one launches the ingest virtualenv by absolute path, because both
    virtualenvs live in the same image; the Azure one starts a Container Apps
    job from the ingest image, where plain ``python`` is already that
    virtualenv's interpreter.
    """
    argv = list(args or [])

    if isinstance(client, PipesSubprocessClient):
        return client.run(
            command=[str(INGEST_PYTHON), "-m", module, *argv],
            context=context,
            extras=extras,
            env=ingest_env(),
        ).get_results()

    # PipesAcaJobClient. Imported lazily by pipeline.resources so that the
    # Azure SDKs are never needed to run locally -- this branch only executes
    # when the code location was built with that client.
    return client.run(
        context=context,
        module=module,
        extras=extras,
        args=argv,
        env=ingest_env(),
    ).get_results()
