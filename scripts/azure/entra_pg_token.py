"""Print an Entra ID access token for Azure Database for PostgreSQL.

Dagster's own run, event and schedule storage authenticates to Postgres
through ``dagster-postgres[azure]``, which mints one of these itself. dbt and
PyAirbyte have no such support: both read a password out of the environment
and pass it straight to libpq. Azure accepts exactly that -- an Entra token
*is* the password, as far as the PostgreSQL wire protocol is concerned -- so
the whole gap closes by putting a token in POSTGRES_PASSWORD before those
processes start. See entrypoint.sh, which is what calls this.

Deliberately importable by both images. It uses azure-identity and the standard
library and nothing else, so it works identically in the orchestrator
virtualenv and the ingest one, which share almost no other dependency.
"""

import os
import sys

# The audience for Azure Database for PostgreSQL Flexible Server. A token for
# any other scope authenticates fine against Entra and is then rejected by the
# database, so this string is load-bearing.
POSTGRES_SCOPE = "https://ossrdbms-aad.database.windows.net/.default"


def main() -> int:
    try:
        from azure.identity import DefaultAzureCredential, ManagedIdentityCredential
    except ImportError:
        print(
            "azure-identity is not installed in this environment; "
            "POSTGRES_PASSWORD cannot be minted from Entra.",
            file=sys.stderr,
        )
        return 1

    # Container Apps can expose more than one identity. DefaultAzureCredential
    # picks the system-assigned one when no client id is given, which is the
    # wrong one here -- every role assignment in infra/ is on the user-assigned
    # identity -- so name it explicitly when we know it.
    client_id = os.environ.get("AZURE_CLIENT_ID")
    if client_id:
        credential = ManagedIdentityCredential(client_id=client_id)
    else:
        credential = DefaultAzureCredential()

    scope = os.environ.get("POSTGRES_ENTRA_SCOPE", POSTGRES_SCOPE)
    token = credential.get_token(scope)

    # No trailing newline: the caller substitutes this into an environment
    # variable, and libpq would send the newline as part of the password.
    sys.stdout.write(token.token)
    return 0


if __name__ == "__main__":
    sys.exit(main())
