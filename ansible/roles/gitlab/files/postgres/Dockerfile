FROM postgres:17.11-bookworm

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl python3-venv \
    && python3 -m venv /opt/patroni \
    && /opt/patroni/bin/pip install --no-cache-dir 'patroni[psycopg3,etcd3]==4.1.5' \
    && rm -rf /var/lib/apt/lists/*

ENV PATH="/opt/patroni/bin:${PATH}" \
    TMPDIR=/dev/shm/patroni \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

COPY --chmod=0755 entrypoint.py /usr/local/bin/postgres-entrypoint.py
COPY --chmod=0755 post-bootstrap.sh /usr/local/bin/post-bootstrap.sh

STOPSIGNAL SIGTERM
ENTRYPOINT ["/opt/patroni/bin/python", "/usr/local/bin/postgres-entrypoint.py"]
CMD []

HEALTHCHECK --interval=10s --timeout=5s --start-period=600s --retries=6 \
    CMD /opt/patroni/bin/python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8008/health', timeout=3)"
