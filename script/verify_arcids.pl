#!/usr/bin/env perl
# verify_arcids.pl -- check that the arcids_idx paging zset is in exact
# agreement with the archive hashes in db0, and optionally repair it.
#
# Why this matters: generate_archive_list() pages over arcids_idx with ZRANGE.
# If the zset ever drifts from the real archive set, pagination silently starts
# skipping or duplicating archives -- every HTTP response still looks healthy
# (200, well-formed JSON), so nothing surfaces in the logs. Counting alone is
# not enough: a stale entry plus a missing entry cancel out and leave ZCARD
# looking correct. This script compares the two SETS, not just their sizes.
#
# What it checks:
#   1. set equality      -- ids only in the index (stale) and only in the
#                           archive hashes (never indexed)
#   2. score uniqueness  -- two archives sharing a sequence number would make
#                           ZRANGE ordering ambiguous
#   3. score contiguity  -- the sequence must be 1..N with no holes. Deletes
#                           only ZREM and never recycle a number, so a hole
#                           means a delete path forgot to sync the index.
#   4. counter agreement -- arcids_idx_seq must equal the highest score
#
# Usage (inside the container):
#   export PERL5LIB=$PERL5LIB
#   perl script/verify_arcids.pl [--fix]
#
# --fix repairs stale entries (ZREM) and unindexed archives (ZADD at fresh
# sequence numbers). It does NOT try to renumber the existing sequence: holes
# are reported but left alone, because renumbering a live index would reshuffle
# pagination mid-scan.
#
# Exit codes: 0 = consistent (or repaired), 1 = drift detected, 2 = usage/conn error.

use strict;
use warnings;
use v5.36;

use Redis;
use Time::HiRes qw(time);

my $fix = grep { $_ eq '--fix' } @ARGV;

# Connect exactly like migrate_arcids.pl: db0, no LANraragi module dependency,
# env-overridable so the script runs on any deployment.
my $server   = $ENV{LRR_REDIS_ADDRESS} // '127.0.0.1:6379';
my $password = $ENV{LRR_REDIS_PASSWORD};
my $db       = $ENV{LRR_REDIS_DATABASE} // 0;

my %args = ( $server =~ m{^/} ? ( sock => $server ) : ( server => $server ) );
$args{password} = $password if $password;

my $redis = Redis->new(%args);
$redis->select($db);

say "connected to $server db$db";
say $fix ? 'FIX MODE -- drift will be repaired' : 'CHECK ONLY';

# 1. The index side. ZRANGE WITHSCORES gives us the sequence numbers too, so we
#    get set membership and score checks from one round trip.
my $t0 = time;
my @flat = $redis->zrange( 'arcids_idx', 0, -1, 'WITHSCORES' );
my @idx_ids;
my @scores;
while (@flat) {
    push @idx_ids, shift @flat;
    push @scores,  shift @flat;
}
say sprintf( 'index: %d ids (%.3fs)', scalar @idx_ids, time - $t0 );

# 2. The archive side. SCAN, not KEYS: KEYS blocks the server for ~2s on a
#    a big-key db, and this script may well be run while the app is live.
my $t1 = time;
my %arch;
my $cursor = 0;
my $scanned = 0;
while (1) {
    my ( $next, $keys ) = $redis->scan( $cursor, 'MATCH', '?' x 40, 'COUNT', 1000 );
    $cursor = $next;
    $scanned += scalar @$keys;
    $arch{$_} = 1 for @$keys;
    last if $cursor == 0;
}
say sprintf( 'archives: %d ids (%.3fs)', scalar( keys %arch ), time - $t1 );

if ( !@idx_ids && !%arch ) {
    say 'both sides are empty -- nothing to verify (is this really db' . $db . '?)';
    $redis->quit;
    exit 0;
}

# 3. Set difference, both directions.
my %idx = map { $_ => 1 } @idx_ids;
my @stale     = grep { !$arch{$_} } @idx_ids;    # in index, not an archive
my @unindexed = grep { !$idx{$_} } keys %arch;   # archive, not in index

# 4. Score checks: duplicates, holes, counter agreement.
my %seen;
my $dupes = 0;
for my $s (@scores) {
    $dupes++ if $seen{$s}++;
}

my @sorted = sort { $a <=> $b } @scores;
my $holes = 0;
for my $i ( 0 .. $#sorted - 1 ) {
    $holes++ if $sorted[ $i + 1 ] != $sorted[$i] + 1;
}
my $max_seq = @sorted ? $sorted[-1] : 0;
my $counter = $redis->get('arcids_idx_seq') // 0;

# 5. Report.
say '';
say '------------------------------ results ------------------------------';
say sprintf( 'stale in index (not an archive) : %d', scalar @stale );
say sprintf( 'missing from index              : %d', scalar @unindexed );
say sprintf( 'duplicate sequence numbers      : %d', $dupes );
say sprintf( 'holes in sequence               : %d', $holes );
say sprintf( 'sequence range                  : %s .. %s',
    ( @sorted ? $sorted[0] : 'n/a' ), ( @sorted ? $sorted[-1] : 'n/a' ) );
say sprintf( 'arcids_idx_seq counter          : %d  (%s)',
    $counter, ( $counter == $max_seq ? 'agrees with max score' : 'MISMATCH' ) );

for my $label ( [ 'stale', \@stale ], [ 'unindexed', \@unindexed ] ) {
    my ( $name, $list ) = @$label;
    next unless @$list;
    say '';
    say "first 5 $name ids:";
    my $n = @$list > 5 ? 4 : $#$list;
    say "  $_" for @$list[ 0 .. $n ];
}

my $drift = @stale || @unindexed || $dupes || $holes || $counter != $max_seq;

# 6. Optional repair. Only the two set-difference cases are fixable; a broken
#    sequence is reported and left alone on purpose.
if ( $drift && $fix ) {
    say '';
    say '------------------------------ repairing ---------------------------';

    if (@stale) {
        my $t2 = time;
        $redis->zrem( 'arcids_idx', @stale );
        say sprintf( 'ZREM %d stale ids (%.3fs)', scalar @stale, time - $t2 );
    }

    if (@unindexed) {
        my $t3 = time;
        my $seq = $counter;
        my $n   = 0;
        my @todo = @unindexed;
        while (@todo) {
            my @chunk = splice( @todo, 0, 10_000 );
            my @zargs;
            push @zargs, ++$seq, $_ for @chunk;
            $redis->zadd( 'arcids_idx', @zargs );
            $n += scalar @chunk;
        }
        $redis->set( 'arcids_idx_seq', $seq );
        say sprintf( 'ZADD %d unindexed ids (%.3fs), seq now %d',
            $n, time - $t3, $seq );
    }

    # Re-verify after repair rather than trusting that the writes landed.
    my $after_zcard = $redis->zcard('arcids_idx');
    my $after_arch  = scalar keys %arch;
    say sprintf( 'post-fix: ZCARD = %d, archives = %d (%s)',
        $after_zcard, $after_arch,
        ( $after_zcard == $after_arch ? 'match' : 'STILL MISMATCHED' ) );

    if ( $after_zcard != $after_arch ) {
        say '';
        say 'VERDICT: REPAIR INCOMPLETE';
        $redis->quit;
        exit 2;
    }

    say '';
    say 'VERDICT: REPAIRED (set membership fixed; re-run without --fix to confirm)';
    $redis->quit;
    exit 0;
}

say '';
if ($drift) {
    say 'VERDICT: DRIFT DETECTED -- re-run with --fix to repair set membership';
    $redis->quit;
    exit 1;
}

say 'VERDICT: CONSISTENT';
$redis->quit;
exit 0;