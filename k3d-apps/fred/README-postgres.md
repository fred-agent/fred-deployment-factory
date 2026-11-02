# Weaver PostgreSQL bootstrap

The checkout's prepare hook invokes `monitor-database --bootstrap <fred>/deploy/postgres/bootstrap.sql`.
Despite its historical name, this hook provisions fred_cp, fred_kf, fred_runtime
and fred_monitor from that single SQL source. Four distinct passwords are kept in
fred-secrets, with resourceVersion protection against concurrent credential changes.
SQL and secret payloads use stdin, and subprocess error output is never logged.
Control Plane migrations grant SELECT on cp_read views; there is no finish-time
GRANT and no --require-table mode.

ENV=secondary sets postgres.applicationBootstrap=true in the infrastructure
chart: its initial SQL does not install vector in the Fred database. The checkout
bootstrap installs it in knowledge. ENV=swift and the separate tabular database
keep their existing extension initialization.

The first Weaver deployment with this boundary requires resetting the disposable
secondary PostgreSQL volume. An old public database is not upgraded or migrated.
To recreate the entire disposable secondary cluster and then deploy:

    make k3d-wipe ENV=secondary
    make k3d-up ENV=secondary
    # Recreate fred-model-credentials from the operator's secret source.
    make k3d-app ENV=secondary APP=fred DIR=../fred

This deletes the secondary cluster's data. Preserve any data that must be retained
before the separately authorized reset. Neither prepare nor finish resets data.
The old fred role and monitor-database Secret are not automatically deleted;
remove them manually only after their old consumers are gone. Transfer database
ownership away from fred before removing that role. Managed installations use the
Fred checkout's deploy/postgres/README.md and an administrator-managed bootstrap.

Run hook tests without a cluster:

    python3 -m unittest discover -s k3d-apps/fred -p 'test_*.py'
