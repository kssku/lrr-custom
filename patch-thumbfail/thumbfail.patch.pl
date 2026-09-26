#!/usr/bin/perl
# 给 LANraragi 打"缩略图失败熔断"补丁
# 机制：Redis 计数器 thumbfail:<id>，连续失败达阈值后不再排队生成，直接回占位图
use strict;
use warnings;

my $base = "/home/koyomi/lanraragi";
my $archive_pm = "$base/lib/LANraragi/Model/Archive.pm";
my $minion_pm  = "$base/lib/LANraragi/Utils/Minion.pm";

my $MAXFAIL = 3;

# ============ 1. 备份 ============
my $ts = time();
system("cp -a '$archive_pm' '$archive_pm.bak-$ts'");
system("cp -a '$minion_pm' '$minion_pm.bak-$ts'");
print "备份完成: .bak-$ts\n";

# ============ 2. Archive.pm: serve_thumbnail 加熔断 ============
open(my $fh, '<', $archive_pm) or die "打不开 $archive_pm: $!";
local $/; my $src = <$fh>; close($fh);

my $old_block = <<'OLD';
    unless ( -e $thumbname ) {

        if ($no_fallback) {

            # Queue a minion job to generate the thumbnail. Thumbnail jobs have the lowest priority.
            my $job_id = $self->minion->enqueue( thumbnail_task => [ $thumbdir, $id, $page ] => { priority => 0, attempts => 3 } );
            $self->render(
                openapi => {
                    operation => "serve_thumbnail",
                    success   => 1,
                    job       => $job_id
                },
                status => 202    # 202 Accepted
            );
        } else {

            # If the thumbnail doesn't exist, serve the default thumbnail.
            $self->render_file( filepath => "./public/img/noThumb.png" );
        }
        return;
    } else {
OLD

my $new_block = <<'NEW';
    unless ( -e $thumbname ) {

        # 熔断检查：该归档的缩略图连续失败次数
        # 目的：坏图会让前端无限重试 -> 每次都要打开 CBZ + 从 CD2 读图 + vips 解码
        #      累积出大量 D 状态进程拖垮容器。达到阈值后直接回占位图，不再排队。
        my $redisfail = LANraragi::Model::Config->get_redis;
        my $failkey   = "thumbfail:$id";
        my $failcount = $redisfail->get($failkey) // 0;
        $redisfail->quit();

        if ( $failcount >= 3 ) {
            my $l = get_logger( "Archive", "lanraragi" );
            $l->warn("Thumbnail generation disabled for $id after $failcount failures (broken archive). Serving placeholder.");
            $self->render_file( filepath => "./public/img/noThumb.png" );
            return;
        }

        if ($no_fallback) {

            # Queue a minion job to generate the thumbnail. Thumbnail jobs have the lowest priority.
            my $job_id = $self->minion->enqueue( thumbnail_task => [ $thumbdir, $id, $page ] => { priority => 0, attempts => 1 } );
            $self->render(
                openapi => {
                    operation => "serve_thumbnail",
                    success   => 1,
                    job       => $job_id
                },
                status => 202    # 202 Accepted
            );
        } else {

            # If the thumbnail doesn't exist, serve the default thumbnail.
            $self->render_file( filepath => "./public/img/noThumb.png" );
        }
        return;
    } else {
NEW

my $cnt = ($src =~ s/\Q$old_block\E/$new_block/) ? 1 : 0;
die "serve_thumbnail 替换失败：未找到目标代码块\n" unless $cnt;
print "Archive.pm: serve_thumbnail 熔断已注入\n";

open(my $out, '>', $archive_pm) or die "写不了 $archive_pm: $!";
print $out $src; close($out);

# ============ 3. Minion.pm: 失败时累加计数器 ============
open($fh, '<', $minion_pm) or die "打不开 $minion_pm: $!";
$src = <$fh>; close($fh);

my $old_task = <<'OLD';
            # Take a shortcut here - Minion jobs can keep the old basic behavior of page 0 = cover.
            eval { $thumbname = extract_thumbnail( $thumbdir, $id, $page, $page eq 0, $use_hq ); };
            if ($@) {
                my $msg = "Error building thumbnail: $@";
                $logger->error($msg);
                $job->fail( { errors => [$msg] } );
            } else {
                $job->finish($thumbname);
            }
OLD

my $new_task = <<'NEW';
            # Take a shortcut here - Minion jobs can keep the old basic behavior of page 0 = cover.
            eval { $thumbname = extract_thumbnail( $thumbdir, $id, $page, $page eq 0, $use_hq ); };
            if ($@) {
                my $msg = "Error building thumbnail: $@";
                $logger->error($msg);

                # 熔断计数：坏图会反复触发失败，累加后在 serve_thumbnail 侧熔断
                # 计数器带 7 天过期，避免 Redis 无限增长
                eval {
                    my $r = LANraragi::Model::Config->get_redis;
                    my $k = "thumbfail:$id";
                    $r->incr($k);
                    $r->expire( $k, 604800 );
                    $r->quit();
                };

                $job->fail( { errors => [$msg] } );
            } else {
                # 成功则清除失败计数
                eval {
                    my $r = LANraragi::Model::Config->get_redis;
                    $r->del("thumbfail:$id");
                    $r->quit();
                };
                $job->finish($thumbname);
            }
NEW

my $cnt2 = ($src =~ s/\Q$old_task\E/$new_task/) ? 1 : 0;
die "thumbnail_task 替换失败：未找到目标代码块\n" unless $cnt2;
print "Minion.pm: thumbnail_task 失败计数已注入\n";

open($out, '>', $minion_pm) or die "写不了 $minion_pm: $!";
print $out $src; close($out);

print "补丁应用完成。\n";
