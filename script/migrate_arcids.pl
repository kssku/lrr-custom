#!/usr/bin/env perl
# migrate_arcids.pl -- build the arcids_idx paging zset from the existing
# archive hashes. Run once, on an existing database, BEFORE deploying the
# feature/path-hash-id fork (the fork falls back to KEYS until the zset exists).
#
# arcids_idx maps archive-id -> monotonic sequence number. generate_archive_list
# pages over it with ZRANGE instead of enumerating all archive hashes with KEYS on
# every request (2.0s -> 0.002s for a 100-entry page).
#
# Idempotent: re-running only adds IDs that are missing from the zset, and the
# sequence counter is left at its current maximum. Safe to run on a live DB.
#
# Usage (inside the container):
#   export PERL5LIB=$PERL5LIB
#   perl script/migrate_arcids.pl [--dry-run]

use strict;
use warnings;
use v5.36;

use Redis;
use Time::HiRes qw(time);

my $dry_run = grep { $_ eq '--dry-run' } @ARGV;

# Connect exactly like LANraragi::Model::Config->get_redis does (db0, the
# archive-hash database). We deliberately do not load the config module here so
# the script can run even if the fork's Perl tree is not fully in @INC.
#
# Defaults match the shipped lrr.conf (redis_address => "127.0.0.1:6379",
# redis_database => "0", empty password). Override with env vars if your
# deployment differs.
my $server   = $ENV{LRR_REDIS_ADDRESS} // '127.0.0.1:6379';
my $password = $ENV{LRR_REDIS_PASSWORD};
my $db       = $ENV{LRR_REDIS_DATABASE} // 0;

my %args = ( $server =~ m{^/} ? ( sock => $server ) : ( server => $server ) );
$args{password} = $password if $password;

my $redis = Redis->new(%args);
$redis->select($db);

say "connected to $server db$db";
say $dry_run ? 'DRY RUN -- no writes will be made' : 'LIVE RUN';

# 1. Collect the current archive IDs. Same pattern the old code used: archive
#    hashes are 40-char hex IDs, and no other key in db0 has that shape.
my $t0   = time;
my @keys = $redis->keys( '?' x 40 );
say sprintf( 'KEYS -> %d archive ids (%.3fs)', scalar @keys, time - $t0 );

die "no archive ids found -- is this really db$db?\n" unless @keys;

# 2. Figure out which ids are already indexed, and the current top score.
my $t1       = time;
my %existing = map { $_ => 1 } $redis->zrange( 'arcids_idx', 0, -1 );
my $seq      = $redis->get('arcids_idx_seq') // 0;
say sprintf(
    'existing index: %d ids, seq=%d (%.3fs)',
    scalar( keys %existing ), $seq, time - $t1
);

# 3. Assign sequence numbers to the ids that are missing, in KEYS order.
my @todo = grep { !$existing{$_} } @keys;
say sprintf( 'to add: %d ids', scalar @todo );

if ( !$dry_run && @todo ) {

    # Chunk the ZADDs: one command with every pair is a multi-megabyte request.
    my $t2 = time;
    my $n  = 0;
    while (@todo) {
        my @chunk = splice( @todo, 0, 10_000 );
        my @args;
        for my $id (@chunk) {
            push @args, ++$seq, $id;
        }
        $redis->zadd( 'arcids_idx', @args );
        $n += scalar @chunk;
    }
    $redis->set( 'arcids_idx_seq', $seq );
    say sprintf( 'ZADD %d ids (%.3fs), seq now %d', $n, time - $t2, $seq );
} elsif ($dry_run) {
    say sprintf( 'would assign seq %d..%d', $seq + 1, $seq + scalar @todo );
}

# 4. Verify: the index must cover every archive hash.
my $zcard = $redis->zcard('arcids_idx');
my $dbsz  = $redis->dbsize;
say sprintf( 'verify: ZCARD arcids_idx = %d, dbsize = %d', $zcard, $dbsz );

if ( $zcard != scalar(@keys) ) {
    say sprintf( 'WARNING: ZCARD (%d) != KEYS count (%d)', $zcard, scalar @keys );
} else {
    say 'OK: index matches the archive count';
}

$redis->quit();
