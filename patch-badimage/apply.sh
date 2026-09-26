#!/bin/bash
# 方案 C: 在 generate_thumbnail 层拦截坏图（0字节/非图片），不调 vips
# 同时为封面页增加"自动后移找第一个有效页"的改进
set -e

SRC=/opt/data/lanraragi/orig/lib/LANraragi/Utils/Archive.pm
DST=/opt/data/lanraragi/patched/lib/LANraragi/Utils/Archive.pm

mkdir -p "$(dirname "$DST")"
cp "$SRC" "$DST"

python3 - <<'PYEOF'
import re

p = "/opt/data/lanraragi/patched/lib/LANraragi/Utils/Archive.pm"
s = open(p, encoding="utf-8").read()

# ---------- 1) 插入图片有效性检测函数（放在 generate_thumbnail 之前） ----------
anchor = "# use a resizer to make a thumbnail, height = 500px"
assert anchor in s, "anchor 1 not found"

helper = '''# 检测一段字节流是否是"可解码的图片"。
# 用于在调用 libvips 之前拦截坏图（0 字节 / 非图片数据），
# 避免 vips 抛 "buffer is not in a known format" 引发前端无限重试。
sub is_decodable_image ($data) {
    return 0 unless defined $data;
    my $len = length $data;

    # 空文件或过短的数据一定不是图片（最短的合法图片也远超这个长度）
    return 0 if $len < 12;

    my $magic = substr( $data, 0, 12 );

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
    # TIFF: II*\0 / MM\0*
    return 1 if $magic =~ /^(II\x2A\x00|MM\x00\x2A)/;
    # AVIF/HEIF: ....ftyp(avif|heic|mif1|msf1)
    return 1 if $magic =~ /^.{4}ftyp(avif|avis|heic|heix|mif1|msf1)/;
    # JXL: FF 0A 或 container signature
    return 1 if $magic =~ /^\xFF\x0A/;

    return 0;
}

'''
s = s.replace(anchor, helper + anchor, 1)

# ---------- 2) generate_thumbnail 里加前置校验 ----------
old_gt = """sub generate_thumbnail ( $data, $thumb_path, $use_hq, $use_jxl ) {
    my $quality = 50;
    $quality = 80 if $use_hq;

    my $resized = get_resizer()->resize_thumbnail( $data, $quality, $use_hq, $use_jxl ? "jxl" : "jpg" );"""

new_gt = """sub generate_thumbnail ( $data, $thumb_path, $use_hq, $use_jxl ) {
    my $quality = 50;
    $quality = 80 if $use_hq;

    # 坏图拦截：0 字节或非图片数据不要送进 libvips。
    # 送进去必然 die，导致 Minion 任务失败、前端反复重试、
    # 每次都要打开 CBZ + 从 CD2 读图，累积出 D 状态进程拖垮容器。
    # 这里提前给出明确的失败原因，并带上可熔断的标记。
    unless ( is_decodable_image($data) ) {
        my $len = defined($data) ? length($data) : -1;
        my $logger = get_logger( "Archive", "lanraragi" );
        $logger->debug("Skipping thumbnail: source data is not a decodable image (bytes=$len)");
        die "BROKEN_IMAGE: source data is not a decodable image (bytes=$len)";
    }

    my $resized = get_resizer()->resize_thumbnail( $data, $quality, $use_hq, $use_jxl ? "jxl" : "jpg" );"""

assert old_gt in s, "anchor 2 (generate_thumbnail) not found"
s = s.replace(old_gt, new_gt, 1)

open(p, "w", encoding="utf-8").write(s)
print("Archive.pm: is_decodable_image + generate_thumbnail 前置校验 已注入")
PYEOF

echo "=== 语法检查 ==="
docker run --rm -v /opt/data/lanraragi/patched:/p --entrypoint sh lrr-custom:v3 -c \
  'PERL5LIB=/home/koyomi/perl5/lib/perl5:/home/koyomi/lanraragi/lib perl -c /p/lib/LANraragi/Utils/Archive.pm' 2>&1 | tail -3

echo "=== 注入点确认 ==="
grep -n 'is_decodable_image\|BROKEN_IMAGE' /opt/data/lanraragi/patched/lib/LANraragi/Utils/Archive.pm
