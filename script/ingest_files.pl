#!/usr/bin/env perl
# ingest_files.pl -- scoped, on-demand ingest of new archives into LANraragi.
#
# WHY THIS EXISTS
# ---------------
# Upstream LANraragi has exactly one way to discover new files: Shinobu walks the
# whole content folder (update_filemap -> find_path) and feeds everything it finds
# through add_new_file. On a local disk that is fine. On a remote FUSE mount (CD2,
# cloud drive) a recursive walk of ~150k archives takes hours and stalls on the
# per-file stat/open, which is why this deployment had to run with
# LRR_DISABLE_SHINOBU=1 -- and that in turn means new files were never picked up
# at all.
#
# This script replaces the walk with an explicit one: you name the directories
# that received new files, and only those are scanned. The traversal cost is
# proportional to the number of files you actually added, not to the size of the
# library.
#
# It is PATH-ONLY, like the fork's Shinobu: IDs are computed by hashing the
# content-relative path, so the script never opens or stats an archive body. The
# one exception is the optional --index step, which reads tags out of db0 (not
# the filesystem) to refresh the search index.
#
# WHAT IT DOES
# ------------
#   1. scan     - Shinobu::update_filemap(@dirs): computes IDs, writes the db0
#                 archive hash (title/tags/file/...), syncs arcids_idx, records
#                 LRR_FILEMAP, and refreshes the search index for each new
#                 archive. Thumbnails and pagecounts are NOT generated (lazy:
#                 they happen the first time the archive is opened in the
#                 reader).
#   2. cache    - invalidate_cache() so the web UI reflects the new data.
#
# Indexing is part of step 1: Shinobu::add_new_file() calls update_indexes() for
# every archive it ingests, so a scanned archive is immediately searchable.
# There is no separate index pass to run (and none is needed -- the old --index
# step was removed because it could not reliably tell which IDs were new).
#
# USAGE (inside the container)
# ----------------------------
#   perl script/ingest_files.pl /content/wnacg/350001-400000
#   perl script/ingest_files.pl --dry-run /content/wnacg/350001-400000
#   perl script/ingest_files.pl --no-index /content/new
#
# Directories may also be given relative to the content folder:
#   perl script/ingest_files.pl wnacg/350001-400000
#
# Exit codes: 0 = ok, 1 = usage/config error, 2 = a step failed.

use strict;
use warnings;
use v5.36;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Getopt::Long qw(GetOptions);
use Time::HiRes  qw(time);
use File::Spec;

# Loading Model::Config pulls in Mojo/Redis and resolves lrr.conf, which is what
# gives us the content dir and both Redis handles. Shinobu already depends on it.
use LANraragi::Model::Config;
use LANraragi::Model::Stats;
use LANraragi::Utils::Path     qw(create_path);
use LANraragi::Utils::Database qw(invalidate_cache);
use LANraragi::Utils::Logging  qw(get_logger);

use Shinobu ();

my $logger = get_logger( "Ingest", "lanraragi" );

# --- options ---------------------------------------------------------------

my ( $dry_run, $no_index, $no_cache );
GetOptions(
    'dry-run'  => \$dry_run,
    'no-index' => \$no_index,
    'no-cache' => \$no_cache,
) or die "bad options; see the header of this script for usage\n";

my @args = @ARGV;
unless (@args) {
    die <<'USAGE';
usage: perl script/ingest_files.pl [--dry-run] [--no-index] [--no-cache] <dir> [<dir> ...]

  <dir>        a directory that received new archives, absolute or relative to
               the content folder. Subdirectories are scanned recursively.
  --dry-run    list what would be ingested; touch nothing.
  --no-index   deprecated no-op; indexing is part of the scan and cannot be
               skipped (an unindexed archive would not be findable by search).
  --no-cache   skip the search-cache invalidation.
USAGE
}

# Resolve relative dirs against the content folder, and refuse the content root
# itself: an unscoped scan is the exact failure mode this whole fork exists to
# avoid.
my $userdir = LANraragi::Model::Config->get_userdir;
my $root    = create_path($userdir);

my @dirs;
for my $d (@args) {
    # create_path() is an identity function on Unix (it only wraps long paths on
    # Windows), so joining is done with File::Spec, not create_path.
    my $abs = ( $d =~ m{^/} ) ? $d : File::Spec->catfile( $userdir, $d );
    $abs = File::Spec->canonpath($abs);

    if ( $abs eq $root ) {
        die "refusing to scan the content root ($root) -- name the subdirectory that received new files\n";
    }
    unless ( -d $abs ) {
        die "not a directory: $abs\n";
    }
    push @dirs, $abs;
}

say "content root : $root";
say "scan roots   : " . join( ', ', @dirs );
say "mode         : " . ( $dry_run ? 'DRY RUN (no writes)' : 'LIVE' );

# --- 1. scan ---------------------------------------------------------------

# update_filemap() prints its own progress through the Shinobu logger, and
# handles the filemap diff (new vs deleted) internally. In dry-run we only want
# to know which files are new, so reproduce that diff read-only instead of
# calling it.
if ($dry_run) {
    my $redis = LANraragi::Model::Config->get_redis_config;

    my @on_disk;
    for my $dir (@dirs) {
        LANraragi::Utils::Path::find_path(
            sub {
                $_ = create_path($_);
                return if -d $_;
                return unless LANraragi::Utils::Generic::is_archive($_);
                push @on_disk, $_;
            },
            $dir
        );
    }

    # Only the filemap entries that live under the scan roots matter; a file
    # recorded elsewhere in the library is not "new" just because it is absent
    # from the current scan.
    my @recorded = $redis->exists("LRR_FILEMAP") ? $redis->hkeys("LRR_FILEMAP") : ();
    my %recorded;
    FILEMAP:
    for my $f (@recorded) {
        for my $dir (@dirs) {
            if ( $f eq $dir || index( $f, create_path($dir) . '/' ) == 0 ) {
                $recorded{$f} = 1;
                next FILEMAP;
            }
        }
    }

    my @new = grep { !$recorded{$_} } @on_disk;

    say '';
    say sprintf( 'would ingest %d new archive(s) from %d file(s) on disk', scalar @new, scalar @on_disk );
    say "  $_" for @new;

    $redis->quit();
    exit 0;
}

my $t0 = time;
$logger->info( 'Ingest: scanning ' . scalar(@dirs) . ' director(ies)' );
Shinobu::update_filemap(@dirs);
$logger->info( sprintf( 'Ingest: scan finished in %.1fs', time - $t0 ) );

# --- 2. index --------------------------------------------------------------
#
# No separate index step is needed. Every archive that update_filemap() ingests
# goes through Shinobu::add_new_file(), which now calls Database::update_indexes()
# itself whenever the archive's tags field is still empty -- i.e. exactly once,
# for exactly the archives that have no index entries yet. The old code here
# tried to re-derive that set afterwards from LRR_TANKGROUPED, which is wrong:
# add_archive_to_redis() writes LRR_TANKGROUPED at ingest time, so the diff was
# always empty and this step silently did nothing.
#
# --no-index is accepted for backwards compatibility but is now a no-op; indexing
# is part of ingest and cannot be skipped without leaving the archive unfindable.
if ($no_index) {
    $logger->warn('Ingest: --no-index is deprecated and ignored; indexing happens during scan.');
}

# --- 3. cache --------------------------------------------------------------

unless ($no_cache) {
    invalidate_cache();
    $logger->info('Ingest: search cache invalidated');
}

say '';
say sprintf( 'done in %.1fs', time - $t0 );
say 'note: thumbnails are NOT generated by this script; they appear the first';
say '      time an archive is opened in the reader (lazy mode).';

exit 0;