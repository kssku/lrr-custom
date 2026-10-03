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
#
# The `cd` is load-bearing, not cosmetic. LANraragi::Model::Config computes
# the project root with Mojo::Home->detect, which is pure cwd sniffing --
# $HOME has no effect on it:
#
#     cwd=/home/koyomi/lanraragi   -> /home/koyomi/lanraragi   (correct)
#     cwd=<s6 oneshot runner dir>  -> that directory             (wrong)
#
# s6-rc runs oneshots with cwd set to the oneshot runner's service
# directory, so without the `cd` Config looks for
#   /run/s6-rc:s6-rc-init:<id>/servicedirs/s6rc-oneshot-runner/lrr.conf
# and dies with "Configuration file ... missing", which propagates through
# Logging.pm and kills rebuild_stats.pl before it writes a single key.
set -e

export HOME=/home/koyomi
cd /home/koyomi/lanraragi
exec s6-setuidgid koyomi /home/koyomi/lanraragi/script/index-init.sh
