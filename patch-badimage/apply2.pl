#!/usr/bin/perl
# 方案 C 补丁：在 generate_thumbnail 层拦截坏图（0字节/非图片），不调 vips
# 用 Perl 直接操作文件，避免 Python/shell 转义层破坏二进制内容
use v5.36;
use strict;
use warnings;
use utf8;

my $file = "/opt/data/lanraragi/patched/lib/LANraragi/Utils/Archive.pm";

# 从干净源重新复制
system("cp", "/opt/data/lanraragi/orig/lib/LANraragi/Utils/Archive.pm", $file) == 0
  or die "copy failed: $!";

open my $fh, '<:raw', $file or die "open: $!";
my $s = do { local $/; <$fh> };
close $fh;

my $anchor = '# use a resizer to make a thumbnail, height = 500px';
index($s, $anchor) >= 0 or die "anchor 1 not found";

# 用单引号 heredoc 保证 \x 系列不被 Perl 解释，写入文件时是字面反斜杠+x
my $helper = <<'PERL_EOF';
# 检测一段字节流是否是"可解码的图片"。
# 用于在调用 libvips 之前拦截坏图（0 字节 / 非图片数据），
# 避免 vips 抛 "buffer is not in a known format" 引发前端无限重试。
sub is_decodable_image ($data) {
    return 0 unless defined $data;
    my $len = length $data;

    # 空文件或过短的数据一定不是图片
    return 0 if $len < 12;

    my $magic = substr( $data, 0, 16 );

    # JPEG: FF D8 FF
    return 1 if $magic =~ /^\xFF\xD8\xFF/;
    # PNG: 89 50 4E 47 0D 0A 1A 0A
    return 1 if $magic =~ /^\x89PNG\x0D\x0A\x1A\x0A/;
    # GIF: GIF87a / GIF89a
    return 1 if $magic =~ /^GIF8[79]a/;
    # WebP: RIFF....WEBP
    return 1 if $magic =~ /^RIFF.{4}WEBP/s;
    # BMP: BM
    return 1 if $magic =~ /^BM/;
    # TIFF: II*\x00 / MM\x00*
    return 1 if $magic =~ /^(II\x2A\x00|MM\x00\x2A)/;
    # AVIF/HEIF: ....ftyp(avif|heic|mif1|msf1)
    return 1 if $magic =~ /^.{4}ftyp(avif|avis|heic|heix|mif1|msf1)/;
    # JXL: FF 0A
    return 1 if $magic =~ /^\xFF\x0A/;

    return 0;
}

PERL_EOF

$s =~ s/\Q$anchor\E/$helper$anchor/ or die "insert helper failed";

my $old_gt = <<'OLD_EOF';
sub generate_thumbnail ( $data, $thumb_path, $use_hq, $use_jxl ) {
    my $quality = 50;
    $quality = 80 if $use_hq;

    my $resized = get_resizer()->resize_thumbnail( $data, $quality, $use_hq, $use_jxl ? "jxl" : "jpg" );
OLD_EOF

my $new_gt = <<'NEW_EOF';
sub generate_thumbnail ( $data, $thumb_path, $use_hq, $use_jxl ) {
    my $quality = 50;
    $quality = 80 if $use_hq;

    # 坏图拦截：0 字节或非图片数据不要送进 libvips。
    # 送进去必然 die，导致 Minion 任务失败、前端反复重试，
    # 每次都要打开 CBZ + 从 CD2 读图，累积出 D 状态进程拖垮容器。
    unless ( is_decodable_image($data) ) {
        my $len    = defined($data) ? length($data) : -1;
        my $logger = get_logger( "Archive", "lanraragi" );
        $logger->debug("Skipping thumbnail: source data is not a decodable image (bytes=$len)");
        die "BROKEN_IMAGE: source data is not a decodable image (bytes=$len)";
    }

    my $resized = get_resizer()->resize_thumbnail( $data, $quality, $use_hq, $use_jxl ? "jxl" : "jpg" );
NEW_EOF

$s =~ s/\Q$old_gt\E/$new_gt/ or die "generate_thumbnail patch failed";

open my $out, '>:raw', $file or die "write open: $!";
print $out $s;
close $out;

say "补丁写入完成";
