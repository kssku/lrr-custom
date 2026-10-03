#!/bin/sh
# Build the search index (db3) on first boot.
#
# This is the s6-rc oneshot `up` target. It is invoked as a single
# executable path from the sibling `up` file -- s6-rc execs that path
# DIRECTLY, without a shell, so this file must exist and be executable.
# (Putting a multi-line shell script with `set -e` inside `up` itself does
# not work: s6-rc tries to exec the first token, `set`, and fails with
# "unable to exec set: No such file or directory" / exit 127.)
#
# Why this service exists: LANraragi::Model::Search::do_search() returns
# (-1,-1,()) whenever LAST_JOB_TIME is missing, so a fresh deployment shows
# "共 -1 件" and a carousel error until the index exists. LAST_JOB_TIME is
# written only by build_stat_hashes(), which in this fork has no automatic
# trigger -- so without this service every new deployment needs a manual
# step.
#
# Behaviour: runs on every container start, but index-init.sh skips the
# rebuild when the index is already present (the common case on restarts).
set -e

export HOME=/home/koyomi
exec s6-setuidgid koyomi /home/koyomi/lanraragi/script/index-init.sh
