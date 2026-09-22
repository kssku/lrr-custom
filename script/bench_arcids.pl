#!/usr/bin/env perl
# bench_arcids.pl -- micro-benchmark for the arcids_idx paging index.
# Measures the Redis-side cost of the paged (ZRANGE) vs legacy (KEYS) paths.
# Read-only; safe to run against a live database.

use strict;
use warnings;
use Redis;
use Time::HiRes qw(time);

my $server = $ENV{LRR_REDIS_ADDRESS} // '127.0.0.1:6379';
my $db     = $ENV{LRR_REDIS_DATABASE} // 0;

my %args = ( $server =~ m{^/} ? ( sock => $server ) : ( server => $server ) );
my $r = Redis->new(%args);
$r->select($db);

sub bench {
    my ( $label, $code ) = @_;
    my $t   = time;
    my $res = $code->();
    my $n   = ref $res eq 'ARRAY' ? scalar @$res : $res;
    printf "%-28s %8.4fs  n=%s\n", $label, time - $t, $n;
    return $res;
}

bench( 'ZRANGE 0 99',    sub { $r->zrange( 'arcids_idx', 0, 99 ) } );
bench( 'ZRANGE 1000 1099', sub { $r->zrange( 'arcids_idx', 1000, 1099 ) } );
bench( 'ZRANGE 0 -1 (full)', sub { $r->zrange( 'arcids_idx', 0, -1 ) } );
bench( 'KEYS ?x40 (legacy)', sub { $r->keys( '?' x 40 ) } );
bench( 'ZCARD',           sub { $r->zcard('arcids_idx') } );
bench( 'DBSIZE',          sub { $r->dbsize } );

$r->quit();
