#!/bin/sh
# index-init.sh -- ensure the search index (db3) exists before LANraragi
# starts serving requests.
#
# Called by the s6 oneshot service `index-init`, which runs after redis is up
# and before lanraragi starts.
#
# WHY
# ---
# LANraragi::Model::Search::do_search() opens with:
#
#     unless ( $redis->exists("LAST_JOB_TIME") ) {
#         return ( -1, -1, () );
#     }
#
# LAST_JOB_TIME is written only by build_stat_hashes(), and in this fork that
# function has no automatic trigger (invalidate_cache() enqueues it only when
# passed a flag that no caller passes, and the startup rebuild is disabled on
# purpose). A fresh deployment therefore serves an empty search index: the
# archive list still works, but the page shows "共 -1 件" and the carousel
# errors out.
#
# BEHAVIOUR
# ---------
#   * LAST_JOB_TIME present  -> do nothing (the common case on every restart
#     after the first). Rebuilding 160k archives takes minutes; there is no
#     reason to pay that on every container start.
#   * LAST_JOB_TIME missing  -> run rebuild_stats.pl once.
#
# A rebuild failure must NOT prevent LANraragi from starting: a broken index
# is a degraded UI, while a failed service dependency would keep the whole
# instance down. Failures are logged and reported, then we exit 0.

set -u

export HOME=/home/koyomi

LRR_DIR=/home/koyomi/lanraragi
VALKEY_CLI=/usr/bin/valkey-cli

# redis_database_search in lrr.conf. Kept in sync with the config file.
SEARCH_DB=3

log() {
    echo "[index-init] $*"
}

# Chdir into the project root before touching perl. LANraragi::Model::Config
# resolves the project root via Mojo::Home->detect, which only ever looks at
# the current directory -- $HOME is ignored. The s6 oneshot that calls us runs
# from the oneshot runner's service directory, where detect() resolves to that
# directory and Config dies looking for lrr.conf. Idempotent and harmless when
# we were already invoked from the right place.
cd "$LRR_DIR" || {
    log "ERROR: cannot cd to $LRR_DIR; skipping index check."
    exit 0
}

# Give redis a moment to accept connections. The s6 dependency only waits for
# the service to be *started*, not for the server to be ready to serve.
i=0
while [ "$i" -lt 30 ]; do
    if "$VALKEY_CLI" -n "$SEARCH_DB" PING >/dev/null 2>&1; then
        break
    fi
    i=$((i + 1))
    sleep 1
done

if ! "$VALKEY_CLI" -n "$SEARCH_DB" PING >/dev/null 2>&1; then
    log "WARNING: redis did not become ready in 30s; skipping index check."
    exit 0
fi

if "$VALKEY_CLI" -n "$SEARCH_DB" EXISTS LAST_JOB_TIME | grep -q '^1$'; then
    log "Search index already present; nothing to do."
    exit 0
fi

log "Search index missing; building it now (this can take a few minutes)."

if perl "$LRR_DIR/script/rebuild_stats.pl"; then
    log "Search index built."
else
    log "ERROR: rebuild_stats.pl failed. The web UI will show an empty"
    log "       archive count until the index is built. Re-run it with:"
    log "         docker exec -u koyomi <container> perl $LRR_DIR/script/rebuild_stats.pl"
fi

# Always succeed: a missing index degrades the UI, it must not block startup.
exit 0
