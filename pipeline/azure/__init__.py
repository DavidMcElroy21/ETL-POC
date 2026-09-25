"""Azure Container Apps integration.

Dagster ships launchers for Kubernetes, Docker and ECS, but not for Container
Apps, so the two pieces that put work into its own container live here:

    run_launcher.AcaJobRunLauncher   one job execution per Dagster run
    pipes.PipesAcaJobClient          one job execution per ingestion step

Everything else -- storage, compute logs, and both halves of the Pipes message
transport -- comes from ``dagster-postgres`` and ``dagster-azure``.

Nothing in this package is imported by the local ``docker compose`` stack. It
is reachable only through ``dagster.azure.yaml`` and the environment switch in
``pipeline/resources.py``, so the Azure SDKs are not needed to run locally.
"""
