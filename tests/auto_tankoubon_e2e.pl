#!/usr/bin/env perl
# auto_tankoubon_e2e.pl -- end-to-end check of the auto-tankoubon hook in
# Shinobu::add_new_file().
#
# The unit tests (tests/tankoubon.t) cover Tankoubon.pm itself but never touch
# the new block in Shinobu.pm: the path regex, the LRR_SERIES_MAP cache, and
# the create-then-add sequence. This script exercises exactly that path against
# a throwaway Redis DB so a regression cannot hide behind the model tests.
#
# It does NOT call Shinobu::add_new_file() (that would drag in plugins,
# indexing and the whole ingest chain). Instead it reproduces the hook's logic
# verbatim against the real Tankoubon functions, which is what the hook itself
# does -- the only thing not covered is the surrounding eval in add_new_file.
#
# Usage: perl -Ilib tests/auto_tankoubon_e2e.pl
# Exit:  0 = all assertions pass, 1 = a check failed.

use strict;
use warnings;
use v5.36;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;

use File::Temp qw(tempdir);
use File::Copy qw(copy);

# --- isolated redis dbs ----------------------------------------------------
# Config.pm reads its database numbers from lrr.conf, resolved through
# Mojo::Home->detect, which honours $MOJO_HOME. Pointing MOJO_HOME at a
# throwaway directory holding our own lrr.conf moves EVERY connection onto
# scratch DBs -- including the ones add_to_tankoubon()/create_tankoubon() open
# internally. A plain SELECT after connecting is NOT enough: those functions
# open their own sockets and would land back on the live DB.
#
# This must run BEFORE Config.pm is compiled: it reads the conf at load time.
my $conf_dir = tempdir( CLEANUP => 1 );
copy( "$FindBin::Bin/../lrr.conf", "$conf_dir/lrr.conf" ) or die "cannot copy lrr.conf: $!";

{
    open my $fh, '<', "$conf_dir/lrr.conf" or die $!;
    local $/;
    my $conf = <$fh>;
    close $fh;

    # Scratch DB numbers, well clear of the live 0-4.
    my %scratch = (
        redis_database         => 9,
        redis_database_minion  => 10,
        redis_database_config  => 11,
        redis_database_search  => 12,
        redis_database_metrics => 13,
    );
    for my $key ( sort keys %scratch ) {
        $conf =~ s/\Q$key\E\s*=>\s*"[^"]*"/$key => "$scratch{$key}"/
            or die "lrr.conf is missing '$key'; refusing to run against the live DB";
    }

    open my $out, '>', "$conf_dir/lrr.conf" or die $!;
    print $out $conf;
    close $out;
}

$ENV{MOJO_HOME} = $conf_dir;

# These MUST be require, not use. A `use` runs at compile time (BEGIN), before
# any runtime statement in this file -- including the MOJO_HOME assignment
# above -- so Config.pm would read the repo's live lrr.conf and every
# connection would land on the production DBs. require defers the load until
# here, when MOJO_HOME already points at the scratch conf.
require LANraragi::Model::Config;
require LANraragi::Model::Tankoubon;
LANraragi::Model::Tankoubon->import(qw(create_tankoubon add_to_tankoubon get_tankoubon));

# --- isolated redis db -----------------------------------------------------
# Config.pm reads its database numbers from lrr.conf, resolved through
# Mojo::Home->detect, which honours $MOJO_HOME. Pointing MOJO_HOME at a
# throwaway directory with our own lrr.conf moves EVERY connection -- including
# the ones add_to_tankoubon()/create_tankoubon() open internally -- onto
# scratch DBs, so the live library is never touched.
#
# This must happen BEFORE Config.pm is compiled: it reads the conf at load time.
#
# No manual SELECT is needed (or wanted): the conf already points archive at db9
# and search at db12, so every connection lands on the right scratch DB by
# construction. A stray select() here would collapse the two DBs into one and
# break the LRR_TANKGROUPED assertions below.
my $TEST_DB = 9;

my $redis        = LANraragi::Model::Config->get_redis;
my $redis_search = LANraragi::Model::Config->get_redis_search;

# Refuse to run against a non-empty scratch DB: a stale key would make the
# cache assertions lie. This must stay: it also guards against the db number
# ever drifting back to a populated one.
my @existing = $redis->keys('*');
plan skip_all => "redis db $TEST_DB is not empty (" . scalar(@existing) . " keys)" if @existing;

# --- seed two fake archives ------------------------------------------------
my @arcs = (
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
);

for my $i ( 0 .. $#arcs ) {
    my $id = $arcs[$i];
    $redis->hset( $id, 'title', "Vol " . ( $i + 1 ) );
    $redis->hset( $id, 'tags',  '' );
    $redis->hset( $id, 'file',  "/content/wnacg/series/doujin/MySeries/vol" . ( $i + 1 ) . ".cbz" );
}

# --- reproduce the hook ----------------------------------------------------
# Kept in sync with lib/Shinobu.pm by hand; if the regex there changes, this
# copy must change too or the e2e stops representing production.
sub auto_tankoubon_hook ( $id, $file ) {
    if ( $file =~ m{/series/[^/]+/([^/]+)/[^/]+$} ) {
        my $series_name = $1;
        my $tank_id     = $redis->hget( "LRR_SERIES_MAP", $series_name );

        unless ($tank_id) {
            $tank_id = create_tankoubon( $series_name, "" );
            $redis->hset( "LRR_SERIES_MAP", $series_name, $tank_id );
        }

        my ( $ok, $err ) = add_to_tankoubon( $tank_id, $id );
        return ( $tank_id, $ok, $err );
    }
    return;
}

# --- 1. path filtering -----------------------------------------------------
ok( "/content/x/series/doujin/MySeries/vol1.cbz" =~ m{/series/[^/]+/([^/]+)/[^/]+$}, 'series path matches' );
is( $1, 'MySeries', 'series name captured verbatim' );

ok( "/content/x/oneshots/foo/bar.cbz" !~ m{/series/[^/]+/([^/]+)/[^/]+$}, 'oneshot path does not match' );
ok( "/content/x/series/MySeries/vol1.cbz" !~ m{/series/[^/]+/([^/]+)/[^/]+$}, 'too-shallow series path does not match' );
ok( "/content/x/series/doujin/MySeries/sub/vol1.cbz" !~ m{/series/[^/]+/([^/]+)/[^/]+$}, 'nested volume dir does not match' );

# --- 2. first volume creates the tank -------------------------------------
my ( $tank_id, $ok, $err ) = auto_tankoubon_hook( $arcs[0], $redis->hget( $arcs[0], 'file' ) );
ok( $tank_id, 'tank id minted for first volume' );
is( $tank_id, $redis->hget( 'LRR_SERIES_MAP', 'MySeries' ), 'tank id cached in LRR_SERIES_MAP' );
ok( $ok, "first volume added ($err)" );

my %tank = get_tankoubon($tank_id);
is( $tank{name}, 'MySeries', 'tank named after the series directory' );
is( scalar @{ $tank{archives} }, 1, 'tank holds exactly one volume' );

# --- 3. second volume reuses the same tank --------------------------------
my ( $tank_id2, $ok2, $err2 ) = auto_tankoubon_hook( $arcs[1], $redis->hget( $arcs[1], 'file' ) );
is( $tank_id2, $tank_id, 'second volume reused the cached tank id (no new tank)' );
ok( $ok2, "second volume added ($err2)" );

%tank = get_tankoubon($tank_id);
is( scalar @{ $tank{archives} }, 2, 'tank now holds both volumes' );

# --- 4. re-ingest is idempotent -------------------------------------------
my ( $tank_id3, $ok3, $err3 ) = auto_tankoubon_hook( $arcs[0], $redis->hget( $arcs[0], 'file' ) );
is( $tank_id3, $tank_id, 're-ingest hit the same tank' );
ok( $ok3, "re-ingest reported success ($err3)" );
like( $err3, qr/already present/, 're-ingest reported the duplicate' );

%tank = get_tankoubon($tank_id);
is( scalar @{ $tank{archives} }, 2, 're-ingest did not duplicate a member' );

# --- 5. only one tank exists ----------------------------------------------
my @tanks = grep { /^TANK_/ } $redis->keys('*');
is( scalar @tanks, 1, 'exactly one tank was created for the series' );

# --- 6. tank grouped set --------------------------------------------------
is( $redis_search->sismember( 'LRR_TANKGROUPED', $arcs[0] ), 0, 'volume 1 hidden from main search' );
is( $redis_search->sismember( 'LRR_TANKGROUPED', $arcs[1] ), 0, 'volume 2 hidden from main search' );
is( $redis_search->sismember( 'LRR_TANKGROUPED', $tank_id ),  1, 'tank exposed to main search' );

# --- cleanup --------------------------------------------------------------
$redis->del($tank_id);
$redis->del(@arcs);
$redis->del('LRR_SERIES_MAP');

# The search side leaves more than LRR_TANKGROUPED behind: add_to_tankoubon()
# also refreshes LRR_TITLES (the title zset) and LRR_SEARCHCACHE. Miss them and
# the next run's db-empty guard trips on this run's leftovers.
$redis_search->del('LRR_TANKGROUPED');
$redis_search->del('LRR_TITLES');
$redis_search->del('LRR_SEARCHCACHE');
$redis->quit;
$redis_search->quit;

done_testing();