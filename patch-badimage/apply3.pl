#!/usr/bin/perl
# Add a circuit breaker to serve_thumbnail in Model/Archive.pm:
# when thumbfail:$id >= 3, stop enqueueing and serve the placeholder.
# NOTE: comments are ASCII-only on purpose (wide-char writes corrupt the file).
use strict;
use warnings;

my $file = shift or die "usage: $0 <Archive.pm>\n";
open my $fh, '<:raw', $file or die "open: $!\n";
local $/;
my $src = <$fh>;
close $fh;

if ( $src =~ /thumbfail/ ) { print "already patched\n"; exit 0; }

my $old = <<'OLD';
        if ($no_fallback) {

            # Queue a minion job to generate the thumbnail. Thumbnail jobs have the lowest priority.
            my $job_id = $self->minion->enqueue( thumbnail_task => [ $thumbdir, $id, $page ] => { priority => 0, attempts => 3 } );
OLD

my $new = <<'NEW';
        if ($no_fallback) {

            # ---- broken-image circuit breaker (patch) ----
            # Count consecutive thumbnail failures per archive (thumbfail:$id, maintained by
            # Model/Minion.pm). Once the threshold is reached, stop enqueueing: without this the
            # frontend retries forever, each retry opening the CBZ + reading CD2 + calling vips,
            # piling up D-state processes and dragging the container down.
            my $fail_count = 0;
            eval {
                my $r = LANraragi::Model::Config->get_redis;
                my $v = $r->get("thumbfail:$id");
                $fail_count = $v if defined $v;
                $r->quit();
            };
            if ( $fail_count >= 3 ) {
                $self->render_file( filepath => "./public/img/noThumb.png" );
                return;
            }

            # Queue a minion job to generate the thumbnail. Thumbnail jobs have the lowest priority.
            my $job_id = $self->minion->enqueue( thumbnail_task => [ $thumbdir, $id, $page ] => { priority => 0, attempts => 3 } );
NEW

my $count = ($src =~ s/\Q$old\E/$new/) ? 1 : 0;
die "anchor not found\n" unless $count;

open my $out, '>:raw', $file or die "write: $!\n";
print $out $src;
close $out;
print "patched: fused ($count)\n";
