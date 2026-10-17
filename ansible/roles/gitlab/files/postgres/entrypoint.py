#!/opt/patroni/bin/python
"""Start Patroni with Docker secrets held only in its private tmpfs files."""

import os
from pathlib import Path
import re
import sys

import yaml


DATA_ROOT = Path("/var/lib/postgresql/data")
RUNTIME_DIR = Path("/dev/shm/patroni")


def read_secret(name):
    try:
        value = (Path("/run/secrets") / name).read_text().strip()
    except OSError:
        raise SystemExit(f"Cannot read Docker secret {name}") from None
    if not re.fullmatch(r"[A-Za-z0-9]+", value):
        raise SystemExit(f"Docker secret {name} must contain only alphanumeric characters")
    return value


def main():
    node_name = os.environ.get("PG_NODE_NAME", "")
    if node_name not in ("postgres-1", "postgres-2", "postgres-3"):
        raise SystemExit("PG_NODE_NAME must be postgres-1, postgres-2 or postgres-3")

    os.umask(0o077)
    DATA_ROOT.mkdir(parents=True, exist_ok=True)
    RUNTIME_DIR.mkdir(mode=0o700, exist_ok=True)
    if os.geteuid() == 0:
        # Only prepare mount roots; never recursively change or erase existing data.
        os.chown(DATA_ROOT, 999, 999)
        os.chown(RUNTIME_DIR, 999, 999)
        os.execvp("gosu", ["gosu", "postgres", sys.executable, __file__])
    if os.geteuid() != 999:
        raise SystemExit("Run this image as root or as the postgres user (UID 999)")
    RUNTIME_DIR.chmod(0o700)

    config = {
        "scope": "gitlab-postgres",
        "namespace": "/bdz/",
        "name": node_name,
        "restapi": {
            "listen": "0.0.0.0:8008",
            "connect_address": f"{node_name}:8008",
            "authentication": {
                "username": "patroni",
                "password": read_secret("patroni_api_password"),
            },
        },
        "etcd3": {
            "hosts": ["etcd-1:2379", "etcd-2:2379", "etcd-3:2379"],
        },
        "bootstrap": {
            "dcs": {
                "ttl": 30,
                "loop_wait": 10,
                "retry_timeout": 10,
                "synchronous_mode": True,
                "synchronous_mode_strict": True,
                "synchronous_node_count": 1,
                "postgresql": {
                    "use_pg_rewind": True,
                    "parameters": {
                        "wal_level": "replica",
                        "shared_buffers": "256MB",
                        "max_connections": 200,
                        "max_wal_senders": 10,
                        "max_replication_slots": 10,
                        "password_encryption": "scram-sha-256",
                    },
                },
            },
            "initdb": [
                {"encoding": "UTF8"},
                {"locale": "C.UTF-8"},
                "data-checksums",
            ],
            "post_bootstrap": "/usr/local/bin/post-bootstrap.sh",
        },
        "postgresql": {
            "listen": "0.0.0.0:5432",
            "connect_address": f"{node_name}:5432",
            "data_dir": str(DATA_ROOT / "pgdata"),
            "bin_dir": "/usr/lib/postgresql/17/bin",
            "pgpass": str(RUNTIME_DIR / "pgpass"),
            "basebackup": [{"checkpoint": "fast"}],
            "use_unix_socket": True,
            "remove_data_directory_on_rewind_failure": False,
            "remove_data_directory_on_diverged_timelines": False,
            "authentication": {
                "superuser": {
                    "username": "postgres",
                    "password": read_secret("postgres_password"),
                },
                "replication": {
                    "username": "replicator",
                    "password": read_secret("replication_password"),
                },
            },
            "parameters": {
                "unix_socket_directories": "/var/run/postgresql",
            },
            "pg_hba": [
                "local all all peer",
                "host all postgres 127.0.0.1/32 scram-sha-256",
                "host replication replicator 127.0.0.1/32 scram-sha-256",
                "host all postgres 172.30.30.0/24 scram-sha-256",
                "host replication replicator 172.30.30.0/24 scram-sha-256",
                "host all postgres 172.30.40.0/24 scram-sha-256",
                "host replication replicator 172.30.40.0/24 scram-sha-256",
                "host gitlabhq_production gitlab 172.30.30.0/24 scram-sha-256",
            ],
        },
    }

    # Any node may win the initial election and execute the post-bootstrap hook.
    read_secret("gitlab_db_password")
    config_path = RUNTIME_DIR / "patroni.yml"
    with config_path.open("w") as config_file:
        yaml.safe_dump(config, config_file, sort_keys=False)
    config_path.chmod(0o600)
    os.environ["TMPDIR"] = str(RUNTIME_DIR)
    os.execvp("patroni", ["patroni", str(config_path)])


if __name__ == "__main__":
    main()
