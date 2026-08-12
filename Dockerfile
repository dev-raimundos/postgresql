FROM postgres:18-alpine

RUN apk add --no-cache --virtual .build-deps \
        build-base \
        git \
        clang21 \
        llvm21 \
    && cd /tmp \
    && git clone --branch v0.8.6 --depth 1 https://github.com/pgvector/pgvector.git \
    && cd pgvector \
    && make \
    && make install \
    && cd /tmp \
    && git clone --branch v4.1 --depth 1 https://github.com/EnterpriseDB/system_stats.git \
    && cd system_stats \
    && make USE_PGXS=1 \
    && make USE_PGXS=1 install \
    && cd / \
    && rm -rf /tmp/pgvector /tmp/system_stats \
    && apk del .build-deps
