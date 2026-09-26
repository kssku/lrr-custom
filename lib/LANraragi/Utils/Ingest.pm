package LANraragi::Utils::Ingest;

# Batched, resumable, adaptive ingest engine.
#
# WHY THIS EXISTS
# ---------------
# Shinobu::update_filemap() is all-or-nothing: it recursively walks every
# configured root with File::Find, collects the full new-file list, then hands
# the whole list to MCE::Loop in one go. On a local disk that is fine. On a
# remote FUSE mount (CloudDrive2) it is not:
#
#   * find_path() -> File::Find does a -d test per entry, which makes the kernel
#     issue getxattr() for POSIX ACLs. CloudFS answers getxattr in bulk badly.
#     Measured on this NAS: a walk of the single shard 1-50000 (26,419 entries)
#     wedges the mount, whereas a breadth-first scan that stops at the shard's
#     CHILDREN (2 levels) yields all 150,743 leaf directories in 9.6s and never
#     wedges.
#
# The critical consequence: the fix cannot be "scan everything, then ingest in
# batches". The SCAN itself is what kills the mount. Batching must bound the
# scan, so the unit of work is a DIRECTORY BATCH, not a file batch.
#
# DESIGN
# ------
# Work is expressed as a list of directories to ingest, taken one batch at a
# time. Each batch is handed to Shinobu::update_filemap(@dirs), which scans only
# those directories (File::Find per directory, bounded size) and does the filemap
# diff, ID computation, db0 write and index refresh. Because the batch holds at
# most $batch_size DIRECTORIES (not files), the per-batch traversal stays small
# even when a directory holds many files.
#
#   1. enumerate the work list: the immediate subdirectories of each root.
#      For /content/wnacg/1-50000 that is its numbered children (1, 10, 10000,
#      ...) -- one readdir of the root, no recursion. Each child is then one
#      unit of work, and ingesting it walks only its own files.
#   2. ingest $batch_size units at a time.
#   3. between batches: check the FUSE waiting counter, save the cursor, and let
#      the adaptive governor adjust the batch size / pause.
#
# This bounds BOTH the scan and the ingest, which is the only shape that
# actually avoids the wedge.
#
# The cursor records which units have been completed, so re-running resumes
# exactly where the last run stopped. Re-ingesting a unit is harmless anyway
# (update_filemap diffs against LRR_FILEMAP), but skipping completed units makes
# a resumed run cheap.

use strict;
use warnings;
use utf8;
use feature qw(say signatures);
no warnings 'experimental::signatures';

use File::Basename;
use File::Spec;
use JSON::PP;
use Time::HiRes qw(time sleep);

use LANraragi::Utils::Logging qw(get_logger);
use LANraragi::Utils::Path    qw(create_path);

use Exporter 'import';
our @EXPORT_OK = qw(enumerate_units ingest_batched fuse_waiting default_cursor_path);

my $logger = get_logger( "Ingest", "lanraragi" );

# --- FUSE health ------------------------------------------------------------

# Sum of the per-connection "waiting" counters under /sys/fs/fuse/connections.
# Each connection exposes the number of requests currently blocked in the
# kernel. A stuck CloudFS request shows up here and never clears on its own, so
# this is the signal to stop before the mount becomes unusable.
sub fuse_waiting {

    my $base = "/sys/fs/fuse/connections";
    return 0 unless -d $base;

    my $total = 0;
    opendir( my $dh, $base ) or return 0;
    for my $conn ( readdir $dh ) {
        next if $conn =~ /^\.\.?$/;
        my $f = "$base/$conn/waiting";
        next unless -r $f;
        if ( open( my $fh, '<', $f ) ) {
            my $n = <$fh>;
            chomp $n if defined $n;
            $total += $n if defined $n && $n =~ /^\d+$/;
            close $fh;
        }
    }
    closedir $dh;

    return $total;
}

# --- work enumeration -------------------------------------------------------

# Enumerate the units of work under a root WITHOUT recursing.
#
# A "unit" is one directory that update_filemap() can be pointed at. We list the
# immediate children of $root and keep the ones that are directories. This is a
# single readdir of $root plus one -d per child -- a bounded, small number of
# operations (a shard has tens of thousands of children at most, and in practice
# a few thousand).
#
# If a root has NO subdirectories, the root itself becomes the single unit, so a
# flat directory of archives still works.
#
# Returns an arrayref of absolute directory paths, sorted for determinism.
sub enumerate_units ($root) {

    my @units;

    opendir( my $dh, $root ) or do {
        $logger->warn("Ingest: cannot open $root: $!");
        return \@units;
    };

    my @entries = readdir $dh;
    closedir $dh;

    for my $name (@entries) {
        next if $name eq '.' || $name eq '..';
        my $path = File::Spec->catfile( $root, $name );
        push @units, $path if -d $path;
    }

    # A root that is itself a leaf (no subdirectories) is one unit.
    @units = ($root) unless @units;

    return [ sort @units ];
}

# --- cursor -----------------------------------------------------------------

sub default_cursor_path {
    my $data = $ENV{LRR_DATA_DIRECTORY} // '/home/koyomi/lanraragi';
    return File::Spec->catfile( $data, 'ingest_cursor.json' );
}

sub _load_cursor ($path) {
    return {} unless defined $path && -r $path;
    open( my $fh, '<', $path ) or return {};
    my $raw = do { local $/; <$fh> };
    close $fh;
    return {} unless defined $raw && length $raw;
    my $data = eval { JSON::PP->new->decode($raw) };
    return ref $data eq 'HASH' ? $data : {};
}

sub _save_cursor ( $path, $data ) {
    return unless defined $path;
    my $tmp = "$path.tmp";
    open( my $fh, '>', $tmp ) or do {
        $logger->warn("Ingest: cannot write cursor $tmp: $!");
        return;
    };
    print {$fh} JSON::PP->new->canonical->pretty->encode($data);
    close $fh;
    rename $tmp, $path or $logger->warn("Ingest: cannot rename cursor $tmp -> $path: $!");
}

# --- batched ingest ---------------------------------------------------------

# Ingest the subdirectories of $roots in batches.
#
#   roots        => [ ... ]   directories whose CHILDREN are the units (required)
#   limit        => 0         max units to ingest this run (0 = unlimited)
#   batch_size   => 50        units per update_filemap() call
#   batch_sleep  => 5         seconds to pause between batches
#   cursor       => path      resume state; undef disables resume
#   adaptive     => 1         shrink/grow batch_size from observed timing
#   dry_run      => 0         enumerate and report, ingest nothing
#
# Note the default batch_size is in UNITS (directories), not files. 50 leaf
# directories of ~1 archive each is a few dozen files per call -- far below the
# point where CloudFS wedges. A user who knows their layout is flat can raise it.
#
# Returns a hashref:
#   { ingested, batches, units, skipped, stopped, reason, elapsed }
#
#   stopped = 0  completed the requested work
#   stopped = 1  hit --limit; safe to resume
#   stopped = 2  aborted (FUSE unhealthy or a batch failed); safe to resume
sub ingest_batched (%opts) {

    my $roots       = $opts{roots}       // [];
    my $limit       = $opts{limit}       // 0;
    my $batch_size  = $opts{batch_size}  // 50;
    my $batch_sleep = $opts{batch_sleep} // 5;
    my $cursor_path = $opts{cursor};
    my $adaptive    = $opts{adaptive}    // 1;
    my $dry_run     = $opts{dry_run}     // 0;

    die "ingest_batched: roots must be a non-empty arrayref\n"
        unless ref $roots eq 'ARRAY' && @$roots;
    die "ingest_batched: batch_size must be >= 1\n" unless $batch_size >= 1;

    # Adaptive governor: $cur_batch floats between $min_batch and $max_batch.
    my $cur_batch = $batch_size;
    my $cur_sleep = $batch_sleep;
    my $min_batch = 1;
    my $max_batch = $batch_size;

    my $cursor    = _load_cursor($cursor_path);
    my %done      = map { $_ => 1 } @{ $cursor->{done} // [] };

    my $result = {
        ingested => 0,
        batches  => 0,
        units    => 0,
        skipped  => 0,
        stopped  => 0,
        reason   => 'completed',
    };

    # Refuse to start on an already-wedged mount: retrying cannot fix it.
    my $w0 = fuse_waiting();
    if ( $w0 > 0 ) {
        $logger->error("Ingest: FUSE already has $w0 stuck request(s); refusing to start. Restart CloudFS first.");
        $result->{stopped} = 2;
        $result->{reason}  = "fuse_unhealthy_before_start(waiting=$w0)";
        return $result;
    }

    my $t_start = time;

    # Build the full unit list up front. Enumeration is one readdir per root plus
    # one -d per child: bounded and safe.
    my @units;
    for my $root (@$roots) {
        my $u = enumerate_units($root);
        $logger->info( sprintf( 'Ingest: %s -> %d unit(s)', $root, scalar @$u ) );
        push @units, @$u;
    }
    $result->{units} = scalar @units;

    if ( !@units ) {
        $logger->info('Ingest: nothing to do.');
        $result->{reason} = 'no_units';
        return $result;
    }

    my $i = 0;

    while ( $i < @units ) {

        if ( $limit && $result->{ingested} >= $limit ) {
            $result->{stopped} = 1;
            $result->{reason}  = "limit_reached($limit)";
            last;
        }

        my $end = $i + $cur_batch - 1;
        $end    = $#units if $end > $#units;
        my @chunk = @units[ $i .. $end ];
        $i = $end + 1;

        # Drop units already completed in an earlier run.
        my @todo = grep { !$done{$_} } @chunk;
        if ( !@todo ) {
            $result->{skipped} += scalar @chunk;
            next;
        }

        my $t0 = time;

        if ($dry_run) {
            $logger->info( sprintf( 'Ingest: [dry-run] would ingest %d unit(s)', scalar @todo ) );
        } else {
            $logger->info( sprintf( 'Ingest: batch %d: %d unit(s)',
                $result->{batches} + 1, scalar @todo ) );

            # update_filemap() scans each named directory with File::Find. The
            # batch bounds how many directories that is, which is what keeps the
            # traversal small. It also does the filemap diff, ID computation,
            # db0 write and index refresh.
            eval { Shinobu::update_filemap(@todo); };
            if ($@) {
                $logger->error("Ingest: batch failed: $@");
                $result->{stopped} = 2;
                $result->{reason}  = "batch_error";
                last;
            }
        }

        my $elapsed = time - $t0;
        $result->{batches}++;
        $result->{ingested} += scalar @todo;

        # Record completion. The cursor is the list of unit paths already done.
        if ($cursor_path) {
            $done{$_} = 1 for @todo;
            $cursor->{done}    = [ sort keys %done ];
            $cursor->{updated} = time;
            _save_cursor( $cursor_path, $cursor );
        }

        # --- health gate -----------------------------------------------------
        my $w = fuse_waiting();
        if ( $w > 0 ) {
            $logger->error("Ingest: FUSE has $w stuck request(s) after batch $result->{batches}; stopping. "
                . "Cursor saved with " . scalar( keys %done ) . " unit(s) done." );
            $result->{stopped} = 2;
            $result->{reason}  = "fuse_unhealthy(waiting=$w)";
            last;
        }

        # --- adaptive governor ----------------------------------------------
        # Timing is per UNIT, so a batch of tiny directories and a batch of huge
        # ones are judged on the same scale.
        if ($adaptive && $result->{batches} > 1) {
            my $per_unit = $elapsed / ( scalar @todo || 1 );

            # Slow (>2s/unit) => halve the batch, double the pause.
            # Fast (<0.2s/unit) => step back toward the configured baseline.
            if ( $per_unit > 2.0 ) {
                my $new = int( $cur_batch / 2 );
                $cur_batch = $new < $min_batch ? $min_batch : $new;
                $cur_sleep = $cur_sleep * 2;
                $cur_sleep = 60 if $cur_sleep > 60;
                $logger->warn( sprintf(
                    'Ingest: slow batch (%.1fs/unit); batch_size -> %d, sleep -> %ds',
                    $per_unit, $cur_batch, $cur_sleep ) );
            } elsif ( $per_unit < 0.2 && $cur_batch < $max_batch ) {
                my $new = int( $cur_batch * 2 );
                $cur_batch = $new > $max_batch ? $max_batch : $new;
                $cur_sleep = int( $cur_sleep / 2 );
                $cur_sleep = $batch_sleep if $cur_sleep < $batch_sleep;
                $logger->info( sprintf(
                    'Ingest: fast batch (%.2fs/unit); batch_size -> %d, sleep -> %ds',
                    $per_unit, $cur_batch, $cur_sleep ) );
            }
        }

        last if $result->{stopped};

        sleep $cur_sleep if $i < @units && $cur_sleep > 0;
    }

    $result->{elapsed} = time - $t_start;
    $logger->info( sprintf( 'Ingest: done in %.1fs: %d unit(s) in %d batch(es), %d skipped, stopped=%d (%s)',
        $result->{elapsed}, $result->{ingested}, $result->{batches},
        $result->{skipped}, $result->{stopped}, $result->{reason} ) );

    return $result;
}

1;
