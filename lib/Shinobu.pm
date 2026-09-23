package Shinobu;

# LANraragi File Watcher.
#  Uses inotify watches to keep track of filesystem happenings.
#  My main tasks are:
#
#    Tracking all files in the content folder and making sure they're sync'ed with the database
#

use strict;
use warnings;
use utf8;
use feature qw(say signatures);
no warnings 'experimental::signatures';

use local::lib;

use FindBin;
use MCE::Loop;
use Storable   qw(lock_store);
use Mojo::JSON qw(to_json);
use Config;

#As this is a new process, reloading the LRR libs into INC is needed.
BEGIN { unshift @INC, "$FindBin::Bin/../lib"; }

use Mojolicious;    # Needed by Model::Config to read the Redis address/port.
use File::ChangeNotify;
use File::Basename;
use File::Spec;
use Encode;

# CUSTOM FORK (feature/path-only-shinobu): extract_thumbnail is deliberately NOT
# imported - Shinobu no longer generates cover thumbnails for new files. It would
# cost two full FUSE reads per archive (get_filelist opens the archive,
# extract_single_file reads the image). Thumbnails are generated lazily instead.
use LANraragi::Utils::Database   qw(invalidate_cache compute_id change_archive_id add_timestamp_tag add_archive_to_redis);
use LANraragi::Utils::Logging    qw(get_logger);
use LANraragi::Utils::Generic    qw(is_archive exec_with_lock_pure);
use LANraragi::Utils::Redis      qw(redis_encode);
# CUSTOM FORK (feature/path-only-shinobu): open_path is deliberately NOT imported.
# The upstream "wait until the file is openable" loop opened the file body, which
# on a FUSE mount (CD2) stalls for ~12.8s per stat/open. Shinobu now only computes
# the path hash and never touches the file body.
use LANraragi::Utils::Path       qw(create_path find_path get_archive_path);

use LANraragi::Model::Config;
use LANraragi::Model::Plugins;
use LANraragi::Model::Metrics;
use LANraragi::Utils::Plugins;    # Needed here since Shinobu doesn't inherit from the main LRR package
use LANraragi::Model::Search;     # idem

use constant IS_UNIX => ( $Config{osname} ne 'MSWin32' );

# Logger and Database objects
my $logger = get_logger( "Shinobu", "shinobu" );

#Subroutine for new and deleted files that takes inotify events
my $inotifysub = sub {
    my $e    = shift;
    my $name = create_path( $e->path );
    my $type = $e->type;

    $logger->debug("Received inotify event $type on $name");

    if ( $type eq "create" || $type eq "modify" ) {
        new_file_callback($name);
    }

    if ( $type eq "delete" ) {
        deleted_file_callback($name);
    }

};

sub initialize_from_new_process {

    if ( !IS_UNIX ) {
        # Enable autoflush
        $| = 1;
    }

    my $userdir = LANraragi::Model::Config->get_userdir;
    my $metrics_enabled = LANraragi::Model::Config->enable_metrics;

    if ($metrics_enabled) {
        LANraragi::Model::Metrics::unregister_shinobu();
    }

    $logger->info("Shinobu File Watcher started.");
    $logger->info("Content folder is $userdir.");

    # CUSTOM FORK (feature/path-only-shinobu): only the explicitly configured
    # directories are scanned and watched. With none configured this is a no-op
    # and the watcher stays inert, so no full-content-root walk ever happens.
    my @watchdirs = get_watch_dirs();

    if (@watchdirs) {
        update_filemap(@watchdirs);
        $logger->info("Initial scan complete! Adding watcher to configured folders to monitor for further file edits.");
    } else {
        $logger->info(
            "No LRR_SHINOBU_WATCH_DIRS configured; skipping initial scan and starting with an empty watch set.");
    }

    # CUSTOM FORK (feature/path-only-shinobu): with no configured directories there
    # is nothing to watch. File::ChangeNotify cannot be given an empty directory
    # list, so the watcher is simply not built and the process idles. This keeps
    # the container running (metrics, Minion) without ever walking the content root.
    my $contentwatcher;
    if (@watchdirs) {
        $contentwatcher = File::ChangeNotify->instantiate_watcher(
            directories     => [@watchdirs],
            filter          => qr/\.(?:zip|rar|7z|tar|tar\.gz|lzma|xz|cbz|cbr|cb7|cbt|cbw|pdf|epub|tar\.zst|zst)$/i,
            follow_symlinks => 1,
            exclude         => [ 'thumb', '.' ],                                                               #excluded subdirs
        );

        my $class = ref($contentwatcher);
        $logger->debug("Watcher class is $class");
    } else {
        $logger->info("Watcher not started (no watch directories). Idling.");
    }

    # manual event loop
    $logger->info("All done! Now dutifully watching your files. ");

    my $running = 1;
    my $metrics_counter = 0;

    while ($running) {
        local $SIG{INT} = sub { $running = 0 };

        # Check events on files
        if ($contentwatcher) {
            for my $event ( $contentwatcher->new_events ) {
                $inotifysub->($event);
            }
        }

        # Collect metrics every 30 seconds (30 * 1 second intervals)
        if ( $metrics_enabled && ++$metrics_counter >= 30 ) {
            LANraragi::Model::Metrics::collect_process_metrics( "shinobu" );
            $metrics_counter = 0;
        }

        sleep 1;
    }

    if ( !IS_UNIX ) {
        # Cleanly shutdown filewatcher
        $contentwatcher->dispose;
    }
}

# Return the list of directories the watcher should scan/watch.
#
# CUSTOM FORK (feature/path-only-shinobu): upstream always walked the whole
# content root. On a FUSE mount (CD2) a recursive walk of ~150k files takes
# hours, which is why the deployment had to set LRR_DISABLE_SHINOBU=1 and the
# file watcher never ran at all.
#
# Instead, the watched roots are configured explicitly:
#
#   LRR_SHINOBU_WATCH_DIRS=/content/wnacg/350001-400000:/content/new
#
# (colon-separated, absolute paths, or paths relative to the content folder).
# Unset/empty => nothing is scanned and nothing is watched: the watcher starts
# but stays inert, which is the safe default and matches the previous
# LRR_DISABLE_SHINOBU=1 behaviour without needing the kill switch.
sub get_watch_dirs {

    my $env = $ENV{LRR_SHINOBU_WATCH_DIRS} // '';
    my @dirs = grep { length } split /:/, $env;

    my $userdir = LANraragi::Model::Config->get_userdir;

    # Relative entries are resolved against the content folder.
    @dirs = map { m{^/} ? $_ : File::Spec->catdir( $userdir, $_ ) } @dirs;

    # Never watch the whole content root: that is the exact case we are avoiding.
    my $root = create_path($userdir);
    @dirs = grep { create_path($_) ne $root } @dirs;

    return @dirs;
}

# Update the filemap. This acts as a masterlist of what's in the content directory.
# This computes IDs for all new archives and henceforth can get rather expensive!
sub update_filemap (@roots) {

    my $redis = LANraragi::Model::Config->get_redis_config;

    # CUSTOM FORK (feature/path-only-shinobu): no roots => never fall back to the
    # full content root. An unscoped scan is the failure mode this fork exists to
    # avoid, so it is simply refused.
    @roots = get_watch_dirs() unless @roots;
    unless (@roots) {
        $logger->info("No watch directories configured (LRR_SHINOBU_WATCH_DIRS); skipping initial scan.");
        $redis->quit();
        return;
    }

    $logger->info( "Scanning " . scalar(@roots) . " configured director(ies) for changes..." );
    my @files;

    # Get all files in the configured directories and their subdirectories.
    foreach my $root (@roots) {
        $logger->info("Scanning $root");

        find_path(
            sub {
                $_ = create_path($_);
                return if -d $_;    #Directories are excluded on the spot
                return unless is_archive($_);
                push @files, $_;    #Push files to array
            },
            $root
        );
    }

    # Cross-check with filemap to get recorded files that aren't on the FS, and new files that aren't recorded.
    #
    # CUSTOM FORK (feature/path-only-shinobu): when the scan is scoped to a
    # subset of the content folder, files recorded under OTHER directories must
    # not be treated as deleted just because this scan did not see them.
    my @filemapfiles = $redis->exists("LRR_FILEMAP") ? $redis->hkeys("LRR_FILEMAP") : ();

    # Match on a DIRECTORY boundary: a root like /content/wnacg/1 must not be
    # treated as a prefix of /content/wnacg/100/foo.cbz.
    my @scoped = grep {
        my $f = $_;
        grep { $f eq $_ || index( $f, create_path($_) . '/' ) == 0 } @roots;
    } @filemapfiles;

    my %filemaphash = map { $_ => 1 } @scoped;
    my %fshash      = map { $_ => 1 } @files;

    my @newfiles     = grep { !$filemaphash{$_} } @files;
    my @deletedfiles = grep { !$fshash{$_} } @scoped;

    $logger->info( "Found " . scalar @newfiles . " new files." );
    $logger->info( scalar @deletedfiles . " files were found on the filemap but not on the filesystem." );

    # Delete old files from filemap
    foreach my $deletedfile (@deletedfiles) {
        $logger->debug("Removing $deletedfile from filemap.");
        $redis->hdel( "LRR_FILEMAP", $deletedfile ) || $logger->warn("Couldn't delete previous filemap data.");
    }

    $redis->quit();

    eval {
        if ( IS_UNIX ) {
            # Now that we have all new files, process them...with multithreading!
            mce_loop {
                add_new_files(@{ $_ });
            } \@newfiles;
            MCE::Loop->finish;
        } else {
            # libarchive does not support threading on Windows
            add_new_files(@newfiles);
        }
    };

    if ($@) {
        $logger->error("Error while scanning content folder: $@");
    }
}

sub add_to_filemap ( $redis_cfg, $file ) {

    my $redis_arc = LANraragi::Model::Config->get_redis;
    if ( is_archive($file) ) {

        $logger->debug("Adding $file to Shinobu filemap.");

        # CUSTOM FORK (feature/path-only-shinobu): Shinobu must never touch the
        # file BODY. The upstream code opened each file and polled its size to
        # wait for a writer to finish:
        #
        #   while (1) { last if open_path(my $h,'<',$file); sleep(1) }   # opens the file
        #   while (1) { last if (-s $file) >= 512000 || ++$cnt >= 5 }    # stats it
        #
        # On a FUSE mount (CD2/cloud drive) a single stat costs ~12.8s, so this
        # turned into a multi-hour stall per file. It is also unnecessary: the
        # ID is a hash of the PATH, not the contents, so a half-written file
        # still gets the correct ID. Readers re-open the file on demand later.
        #
        # The only remaining assumption is that the caller passed us a path
        # that exists (inotify create/modify event, or an explicit scan).

        # Compute the ID from the PATH alone - no open(), no stat().
        my $id = compute_id($file);

        # Acquire exclusive metadata and file write access for archive by ID with 1m timeout
        my ($acquired, $is_new) = exec_with_lock_pure(
            [ "archive-write:$id" ],
            sub { update_filemap_entry( $logger, $id, $file, $redis_cfg, $redis_arc ) },
            undef, 60
        );

        if ( !$acquired ) {
            $logger->warn("Write lock already acquired for archive $file with ID $id, skipping.");
        }

        # New file handling runs outside the lock so auto-plugin can acquire its own lock.
        if ( $acquired && $is_new ) {
            add_new_file( $id, $file );
            invalidate_cache();
        }

    } else {
        $logger->debug("$file not recognized as archive, skipping.");
    }
    $redis_arc->quit;
}

sub update_filemap_entry ( $logger, $id, $file, $redis_cfg, $redis_arc ) {

    $logger->debug("Computed ID is $id.");

    # CUSTOM FORK (feature/path-only-shinobu): the upstream -e check was a race
    # guard for a file deleted between ID computation and lock acquisition. It
    # costs a stat (~12.8s on FUSE) and the race is harmless: a vanished file
    # simply yields an archive entry the reader cannot open, and the next
    # delete event prunes it. Removed deliberately.

    # If the id already exists on the server, throw a warning about duplicates
    if ( $redis_cfg->hexists( "LRR_FILEMAP", $file ) ) {

        my $filemap_id = $redis_cfg->hget( "LRR_FILEMAP", $file );

        $logger->debug("$file was logged but is already in the filemap!");

        if ( $filemap_id ne $id ) {
            $logger->debug("$file has a different ID than the one in the filemap! ($filemap_id)");
            $logger->info("$file has been modified, updating its ID from $filemap_id to $id.");

            # Note: The logic here is technically different than the one in Upload.pm.
            # Upload.pm checks replace_duplicates and wipes the previous ID/metadata. 
            # Shinobu just updates the ID in the database and leaves the old metadata in place.
            # There's no way to assess user intent just from a filewatcher though, so we act non-destructively.
            change_archive_id( $filemap_id, $id );

            # Don't forget to update the filemap, later operations will behave incorrectly otherwise
            $redis_cfg->hset( "LRR_FILEMAP", $file, $id );
        } else {
            $logger->debug(
                "$file has the same ID as the one in the filemap. Duplicate inotify events? Cleaning cache just to make sure");
            invalidate_cache();
        }

        return;

    } else {
        $redis_cfg->hset( "LRR_FILEMAP", $file, $id );    # raw FS path so no encoding/decoding whatsoever
    }

    # Filename sanity check
    if ( $redis_arc->exists($id) ) {

        my $filecheck = get_archive_path( $redis_arc, $id );

        #Update the real file path and title if they differ from the saved one
        #This is meant to always track the current filename for the OS.
        unless ( $file eq $filecheck ) {
            $logger->debug("File name discrepancy detected between DB and filesystem!");
            $logger->debug("Filesystem: $file");
            $logger->debug("Database: $filecheck");
            my ( $name, $path, $suffix ) = fileparse( $file, qr/\.[^.]*/ );
            $redis_arc->hset( $id, "file", $file );
            $redis_arc->hset( $id, "name", redis_encode($name) );
            $redis_arc->wait_all_responses;
            invalidate_cache();
        }

        # CUSTOM FORK (feature/path-only-shinobu): arcsize and pagecount both
        # require touching the file itself.
        #
        #   add_arcsize    -> -s $file          (stat, ~12.8s on FUSE)
        #   add_pagecount  -> get_filelist()    (OPENS the archive, reads its TOC)
        #
        # Neither is needed for the archive to be listed or searched: pagecount
        # is only used by the reader, which opens the file anyway. They are now
        # filled in lazily the first time an archive is actually read.
        $logger->debug("Skipping arcsize/pagecount for $id (path-only mode).");

    } else {

        # Signal that this is a new file; caller will handle add_new_file outside the lock.
        return 1;
    }

    return 0;
}

# Only handle new files. As per the ChangeNotify doc, it
# "handles the addition of new subdirectories by adding them to the watch list"
sub new_file_callback ($name) {

    $logger->debug("New file detected: $name");
    unless ( -d $name ) {

        my $redis = LANraragi::Model::Config->get_redis_config;
        eval { add_to_filemap( $redis, $name ); };
        $redis->quit();

        if ($@) {
            $logger->error("Error while handling new file: $@");
        }
    }
}

# Deleted files are simply dropped from the filemap.
# Deleted subdirectories trigger deleted events for every file deleted.
sub deleted_file_callback ($name) {

    $logger->info("$name was deleted from the content folder!");
    unless ( -d $name ) {

        my $redis = LANraragi::Model::Config->get_redis_config;

        # Prune file from filemap
        $redis->hdel( "LRR_FILEMAP", $name );

        eval { invalidate_cache(); };

        $redis->quit();
    }
}

sub add_new_files (@files) {
    my $redis = LANraragi::Model::Config->get_redis_config;

    foreach my $file (@files) {
        $logger->debug("Processing $file");

        # Individual files are also eval'd so we can keep scanning
        eval { add_to_filemap( $redis, $file ); };

        if ($@) {
            $logger->error("Error scanning $file: $@");
        }
    }

    $redis->quit();
}


sub add_new_file ( $id, $file ) {

    my $redis        = LANraragi::Model::Config->get_redis;
    my $redis_search = LANraragi::Model::Config->get_redis_search;
    $logger->info("Adding new file $file with ID $id");

    eval {
        add_archive_to_redis( $id, $file, $redis, $redis_search );
        add_timestamp_tag( $redis, $id );

        # CUSTOM FORK (feature/path-only-shinobu): pagecount comes from
        # get_filelist(), which OPENS the archive and reads its table of contents.
        # Removed here for the same reason as arcsize above - it is only needed by
        # the reader, which opens the file anyway.

        # CUSTOM FORK (feature/path-only-shinobu / lazy-thumbnails): the upstream
        # code generated a cover thumbnail for every new archive. extract_thumbnail
        # does TWO full FUSE reads (get_filelist opens the archive; extract_single_file
        # reads the image), so a bulk import paid ~2 stat+open per file.
        #
        # Thumbnails are now generated lazily, the first time an archive is actually
        # opened in the reader (or explicitly via
        # GET /api/archives/<id>/thumbnail?no_fallback=true). Until then the UI
        # serves public/img/noThumb.png, which costs nothing.
        $logger->debug("Skipping thumbnail generation for $id (lazy mode).");

        # AutoTagging using enabled plugins goes here!
        LANraragi::Model::Plugins::exec_enabled_plugins_on_file($id);

        # CUSTOM FORK (feature/path-only-shinobu): refresh the search indexes for
        # this one archive, right where every ingest path converges.
        #
        # Why here: add_archive_to_redis() writes tags="" straight to db0 with
        # hset, bypassing set_tags() -> update_indexes(). The only other thing that
        # could fill INDEX_* is the startup full rebuild (build_stat_hashes),
        # which this fork disables. So without this call a newly ingested archive
        # exists in db0 but is invisible to search until a manual rescan.
        #
        # update_indexes() is incremental (no flushdb, no full walk) and reads
        # tags out of db0, never the filesystem. oldtags="" because the archive
        # was just created; this makes the LRR_STATS zincrby +1 per tag correct on
        # the first (and only) call.
        #
        # Plugins may have already added tags via set_tags(), which itself calls
        # update_indexes() -- re-running here would double-count LRR_STATS.
        #
        # The reliable signal is set_tags()'s own behaviour: whenever it runs it
        # writes the encoded tag string into db0. add_archive_to_redis() writes
        # the empty string. So a non-empty "tags" field means indexing already
        # happened and we must NOT re-run it; an empty one means nothing has
        # indexed this archive yet.
        #
        # NOTE: update_indexes() does NOT read tags out of db0 itself -- it only
        # indexes the tag strings handed to it. Passing "" as newtags would index
        # nothing and merely mark the archive untagged. So we must read the tags
        # ourselves and hand them over. Encoding: update_indexes() expects the
        # same plaintext form set_tags() passes it (it redis_encode()s each tag
        # internally), while db0 stores the encoded form -- hence the decode.
        my $current_tags = $redis->hget( $id, "tags" ) // "";
        if ( $current_tags eq "" ) {
            # Nothing has indexed this archive yet. update_indexes() does not read
            # db0 itself, so hand it the archive's actual tags; otherwise the
            # INDEX_* sets stay empty and the archive is unsearchable. Tags are
            # stored encoded and update_indexes() expects plaintext (it encodes
            # each tag itself), hence the decode.
            my $tags = LANraragi::Utils::Redis::redis_decode($current_tags);
            $logger->debug("Indexing new archive $id (tags: $tags).");
            LANraragi::Utils::Database::update_indexes( $id, "", $tags );
        }
        else {
            $logger->debug("Skipping index refresh for $id (tags already indexed by set_tags).");
        }
    };

    if ($@) {
        $logger->error("Error while adding file: $@");
    }
    $redis->quit;
    $redis_search->quit;
}

__PACKAGE__->initialize_from_new_process unless caller;

1;
