FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends openssh-client \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /root/.ssh && ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N "" -q

WORKDIR /app
COPY server.py index.html _sidebar.md ./
COPY asd-tunnel /usr/local/bin/asd-tunnel
RUN chmod +x /usr/local/bin/asd-tunnel
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV PROJECT_ROOT=/docs
ENV DOCS_PORT=8080
ENV DOCS_BIND=0.0.0.0

ENTRYPOINT ["/entrypoint.sh"]
