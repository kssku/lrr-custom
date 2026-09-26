#!/usr/bin/env perl
# ingest_batched.pl -- ingest new archives in small, resumable batches.
#
# WHY THIS EXISTS
# ---------------
# script/ingest_files.pl calls Shinobu::update_filemap() once per named
# directory. That is scoped, which already beats a full-content-root walk, but it
# is still unbounded: point it at /content/wnacg/1-50000 and update_filemap walks
# all 26,419 entries in one go. On CloudDrive2 that wedges the FUSE mount.
#
# The wedge is caused by the SCAN, not by the database writes, so "scan it all
# then ingest in batches" does not help. This script bounds the scan: it treats
# the immediate subdirectories of each named root as units of work and ingests a
# few units per call to update_filemap(). A unit is a leaf directory such as
# /content/wnacg/1-50000/1, so each call walks only that directory's own files.
#
# Between batches it checks the kernel's FUSE "waiting" counter and stops if the
# mount is unhealthy. A cursor file records completed units, so a stopped run
# resumes exactly where it left off.
#
# A 150k-file library becomes many small runs, or one long run that paces itself
# and can be interrupted at any point without losing progress.
#
# USAGE (inside the container)
# ----------------------------
#   perl script/ingest_batched.pl wnacg/350001-400000
#   perl script/ingest_batched.pl --limit 100 --batch-size 20 --sleep 10 wnacg/1-50000
#   perl script/ingest_batched.pl --dry-run wnacg
#   perl script/ingest_batched.pl --no-cursor --limit 50 wnacg/50001-100000
#
# Directories may be absolute or relative to the content folder. The scan covers
# the CHILDREN of each named directory; name a leaf directory to ingest just it.
#
# Exit codes:
#   0 = completed the requested work
#   1 = usage/config error
#   2 = aborted (FUSE unhealthy or a batch failed) -- safe to re-run
#   3 = stopped early (--limit reached)            -- safe to re-run
#
# Re-running is always safe: completed units are skipped via the cursor, and
# update_filemap() itself diffs against LRR_FILEMAP.

use strict;
use warnings;
use utf8;
use feature qw(say signatures);
no warnings 'experimental::signatures';

use FindBin;
use lib "$FindBin::Bin/../lib";

use Getopt::Long qw(GetOptions);
use File::Spec;
use Time::HiRes qw(time);

use LANraragi::Model::Config;
use LANraragi::Utils::Path     qw(create_path);
use LANraragi::Utils::Database qw(invalidate_cache);
use LANraragi::Utils::Logging  qw(get_logger);
use LANraragi::Utils::Ingest   qw(ingest_batched enumerate_units default_cursor_path fuse_waiting);

use Shinobu ();

my $logger = get_logger( "Ingest", "lanraragi" );

# --- options ----------------------------------------------------------------

my ( $limit, $batch_size, $sleep, $cursor, $no_cursor, $adaptive, $dry_run, $no_cache, $help );
$limit      = 0;
$batch_size = 50;    # units (directories), not files
$sleep      = 5;
$adaptive   = 1;

GetOptions(
    'limit=i'      => \$limit,
    'batch-size=i' => \$batch_size,
    'sleep=i'      => \$sleep,
    'cursor=s'     => \$cursor,
    'no-cursor'    => \$no_cursor,
    'adaptive!'    => \$adaptive,
    'dry-run'      => \$dry_run,
    'no-cache'     => \$no_cache,
    'help|h'       => \$help,
) or die "bad options; see --help\n";

if ($help) {
    print <<'USAGE';
usage: perl script/ingest_batched.pl [options] <dir> [<dir> ...]

  <dir>            a directory whose subdirectories hold new archives,
                   absolute or relative to the content folder.

  --limit N        ingest at most N units this run (default: 0 = no limit).
  --batch-size N   units per update_filemap() call (default: 50).
  --sleep S        seconds to pause between batches (default: 5).
  --cursor FILE    resume-state file (default: <data>/ingest_cursor.json).
  --no-cursor      do not read or write a cursor.
  --adaptive       shrink the batch size and grow the pause when batches are
                   slow, and recover when they are fast (default: on).
  --no-adaptive    use the fixed --batch-size / --sleep values.
  --dry-run        enumerate and report; ingest nothing.
  --no-cache       skip the search-cache invalidation.

exit codes:
  0  completed          1  usage error
  2  aborted (resume)   3  stopped early (resume)

Re-running is safe: completed units are skipped via the cursor.
USAGE
    exit 0;
}

my @args = @ARGV;
unless (@args) {
    die "usage: perl script/ingest_batched.pl [options] <dir> [<dir> ...]  (see --help)\n";
}

die "--batch-size must be >= 1\n" if $batch_size < 1;
die "--sleep must be >= 0\n"      if $sleep < 0;
die "--limit must be >= 0\n"      if $limit < 0;

# --- resolve roots ----------------------------------------------------------

# Resolve relative dirs against the content folder and refuse the content root
# itself. An unscoped scan of the whole library is the failure mode this script
# exists to avoid.
my $userdir = LANraragi::Model::Config->get_userdir;
my $root    = create_path($userdir);

my @dirs;
for my $d (@args) {
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

my $cursor_path = $no_cursor ? undef : ( $cursor // default_cursor_path() );

# --- plan -------------------------------------------------------------------

# Enumerate up front so the run can be described before it starts. This is the
# same enumeration ingest_batched() performs, so it is bounded and safe.
my $planned = 0;
for my $d (@dirs) {
    $planned += scalar @{ enumerate_units($d) };
}

say "content root : $root";
say "scan roots   : " . join( ', ', @dirs );
say "mode         : " . ( $dry_run ? 'DRY RUN (no writes)' : 'LIVE' );
say "units        : $planned subdirector(ies) to consider";
say "batch size   : $batch_size unit(s) (adaptive: " . ( $adaptive ? 'on' : 'off' ) . ")";
say "limit        : " . ( $limit ? "$limit unit(s)" : 'unlimited' );
say "cursor       : " . ( $cursor_path // '(disabled)' );
say "fuse waiting : " . fuse_waiting();

# --- run --------------------------------------------------------------------

my $t0 = time;

my $result = ingest_batched(
    roots       => \@dirs,
    limit       => $limit,
    batch_size  => $batch_size,
    batch_sleep => $sleep,
    cursor      => $cursor_path,
    adaptive    => $adaptive,
    dry_run     => $dry_run,
);

# --- cache ------------------------------------------------------------------

unless ( $no_cache || $dry_run ) {
    invalidate_cache();
    $logger->info('Ingest: search cache invalidated');
}

# --- report -----------------------------------------------------------------

say '';
say sprintf( 'units    : %d total, %d ingested, %d skipped',
    $result->{units} // 0, $result->{ingested}, $result->{skipped} );
say sprintf( 'batches  : %d', $result->{batches} );
say sprintf( 'elapsed  : %.1fs', $result->{elapsed} // ( time - $t0 ) );
say sprintf( 'stopped  : %d (%s)', $result->{stopped}, $result->{reason} );

if ( $result->{stopped} == 0 ) {
    say 'done.';
    say 'note: thumbnails are NOT generated here; they appear the first time an';
    say '      archive is opened in the reader (lazy mode).';
    exit 0;
}

if ( $result->{stopped} == 1 ) {
    say "stopped early: limit reached. re-run the same command to continue.";
    exit 3;
}

say "aborted: $result->{reason}.";
say "the cursor was saved, so re-running continues where this run stopped.";
if ( $result->{reason} =~ /fuse/ ) {
    say "note: if the FUSE mount is wedged, CloudFS must be restarted before retrying.";
}
exit 2;
