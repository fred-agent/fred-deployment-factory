# Weaver PostgreSQL bootstrap

The checkout's prepare hook invokes `monitor-database --bootstrap <fred>/deploy/postgres/bootstrap.sql`.
Despite its historical name, this hook provisions fred_cp, fred_kf, fred_runtime
and fred_monitor from that single SQL source. Four distinct passwords are kept in
fred-secrets, with resourceVersion protection against concurrent credential changes.
SQL and secret payloads use stdin, and subprocess error output is never logged.
Control Plane migrations grant SELECT on cp_read views; there is no finish-time
GRANT and no --require-table mode.

Weaver always uses the separate database `fred_weaver`; its product bootstrap
installs vector in the knowledge schema. Swift's `fred` database and the independent
tabular database retain their infrastructure extension initialization.

Run `make k3d-up-weaver` or `make k3d-up-migration` from the factory. Neither prepare nor
finish resets data. A disposable lab can be reset explicitly with `make k3d-wipe`;
this deletes all Swift and Weaver data, not just PostgreSQL. See the factory README.
Managed installations use the Fred checkout's deploy/postgres/README.md and an
administrator-managed bootstrap. Applied migration history remains immutable.

Run hook tests without a cluster:

    python3 -m unittest discover -s k3d-apps/fred -p 'test_*.py'
