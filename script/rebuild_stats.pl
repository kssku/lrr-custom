#!/usr/bin/env perl
# rebuild_stats.pl -- build (or rebuild) the search-index hashes in the
# search database (db3 by default).
#
# WHY THIS SCRIPT EXISTS
# ----------------------
# LANraragi::Model::Search::do_search() starts with:
#
#     unless ( $redis->exists("LAST_JOB_TIME") ) {
#         return ( -1, -1, () );
#     }
#
# LAST_JOB_TIME is written *only* by
# LANraragi::Model::Stats::build_stat_hashes(), and in this fork that function
# had no normal trigger: invalidate_cache() only enqueues it when called with
# the (currently never-passed) $rebuild_indexes flag, and the startup rebuild
# is deliberately disabled. The result on a fresh deployment is a UI that
# shows "共 -1 件" and a carousel error -- the index DB is simply empty.
#
# Run this once after the first ingest completes on a new deployment, and any
# time the index looks stale. It is safe to re-run: build_stat_hashes()
# replaces the whole index in one Redis transaction.
#
# IMPORTANT -- RUN IT AS koyomi, NOT AS ROOT
# ------------------------------------------
# This script writes LRR's own log file. If it is run as root (e.g. a bare
# `docker exec` without -u), the log file is recreated owned by root and the
# koyomi-run web server can no longer write to it, which makes every HTTP
# request fail with 500. Run it through the container's normal user, e.g.:
#
#     docker exec -u koyomi lrr <this script>
#
# or, from inside the container (already running as koyomi):
#
#     perl script/rebuild_stats.pl
#
# Usage:
#   perl script/rebuild_stats.pl [--quiet]

use strict;
use warnings;
use v5.36;

my $quiet = grep { $_ eq '--quiet' } @ARGV;

# Refuse to run as root: get_logger() below opens LRR's own log file. A root
# run recreates it owned by root, after which the koyomi-run web server can no
# longer append to it and *every* HTTP request starts failing with 500. This
# guard turns a silent, hard-to-diagnose breakage into an immediate error.
if ( $> == 0 ) {
    die "rebuild_stats.pl must not run as root.\n"
      . "Run it as the LRR user instead:\n"
      . "  docker exec -u koyomi <container> perl /home/koyomi/lanraragi/script/rebuild_stats.pl\n";
}

# Two module trees are needed.
#
# 1. The local::lib install under $HOME/perl5. Use local::lib itself rather
#    than hand-adding paths: it also adds the *architecture* subdirectory
#    (perl5/lib/perl5/x86_64-linux-thread-multi), which is where every XS
#    module lives. Hand-adding only perl5/lib/perl5 finds pure-Perl modules
#    such as Redis.pm but fails on FFI::Platypus::Buffer and friends with a
#    confusing "Can't locate ... in @INC" that looks like a missing package.
#    This is exactly what script/lanraragi (LRR's own launcher) does.
#
# 2. LRR's own lib/ directory (LANraragi::*). The web server gets it from its
#    launcher; a standalone script has to add it explicitly.
BEGIN {
    # Two module trees are needed:
    #
    #   1. the local::lib install, which is where every CPAN dependency lives
    #      (Redis, Mojo, Archive::Libarchive, ...);
    #   2. LRR's own lib/ directory (LANraragi::*).
    #
    # Deliberately NOT "use local::lib": local::lib derives its path from
    # $HOME *and* from PERL5LIB / PERL_LOCAL_LIB_ROOT / PERL_MB_OPT. Under a
    # bare `docker exec` those are either unset or stale, and the module then
    # resolves to $HOME/lib/perl5/... while the tree actually lives in
    # $HOME/perl5/lib/perl5/... -- so every load dies with "Can't locate
    # Redis.pm in @INC". The web server never hits this because s6 starts it
    # through script/launcher.pl with a clean environment. Adding the two real
    # paths directly is what makes this script behave the same either way.
    #
    # The architecture subdirectory matters: XS modules (FFI::Platypus::Buffer
    # and friends) are installed under x86_64-linux-thread-multi/, so a
    # lib/perl5-only path finds pure-Perl modules but fails on those with a
    # misleading "Can't locate ... in @INC".
    my $home = $ENV{HOME} // '';
    $home = '/home/koyomi' unless $home ne '' && -d "$home/perl5/lib/perl5";
    $ENV{HOME} = $home;

    my $lib = "$home/perl5/lib/perl5";
    if ( -d $lib ) {
        unshift @INC, $lib;
        unshift @INC, "$lib/x86_64-linux-thread-multi"
          if -d "$lib/x86_64-linux-thread-multi";
    }

    my $lrrdir = $ENV{LRR_DIR} // '/home/koyomi/lanraragi';
    unshift @INC, "$lrrdir/lib" if -d "$lrrdir/lib";
}

use LANraragi::Model::Stats;
use LANraragi::Utils::Logging qw(get_logger);

my $logger = get_logger( "Tag Stats", "lanraragi" );

# Report where we are writing so a mis-targeted run is obvious.
my $config = do {
    local $@;
    eval { require LANraragi::Model::Config; LANraragi::Model::Config->get_searchdb };
} // '?';

say "Building search indexes into the search database (db$config)..." unless $quiet;

my $started = time();
LANraragi::Model::Stats::build_stat_hashes();
my $elapsed = time() - $started;

say sprintf( "Done in %.1fs.", $elapsed ) unless $quiet;
