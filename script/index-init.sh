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

# Wait until redis is actually *serving*, not merely started.
#
# The s6 dependency only waits for the service to be started; the server is
# still reading its dataset from disk at that point. During that window every
# command answers with the error "LOADING Valkey is loading the dataset in
# memory", and valkey-cli exits non-zero -- so a readiness test that only
# checks the exit status can appear to succeed for the wrong reason, and worse,
# an EXISTS issued in that window aborts the rebuild (observed as:
#   [hexists] LOADING Valkey is loading the dataset in memory, at Redis.pm line 321.
#   [index-init] ERROR: rebuild_stats.pl failed.
# on a database large enough to take a few seconds to load).
#
# So match the literal PONG payload instead: that is the only answer meaning
# "ready to serve". LOADING and connection errors both fail the match and we
# keep waiting.
REDIS_READY=0
i=0
while [ "$i" -lt 60 ]; do
    if [ "$("$VALKEY_CLI" -n "$SEARCH_DB" PING 2>/dev/null)" = "PONG" ]; then
        REDIS_READY=1
        break
    fi
    i=$((i + 1))
    sleep 1
done

if [ "$REDIS_READY" -ne 1 ]; then
    log "WARNING: redis did not become ready in 60s; skipping index check."
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
