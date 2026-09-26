#!/usr/bin/perl
# 验证坏图防护补丁：直接对已知坏图（0 字节封面）调用 extract_thumbnail
use strict;
use warnings;
use lib '/home/koyomi/lanraragi/lib';

use LANraragi::Utils::Archive;
use LANraragi::Model::Config;

my $thumbdir = '/home/koyomi/lanraragi/thumb';

# 74993 的 archive id（从之前日志中拿到）
my $id = 'c6909bd0d9532ba3f0451cd103905d812a06fe59';

print "=== 1. 测试 is_decodable_image 对空串/正常 JPEG ===\n";
my $empty = "";
my $ok = LANraragi::Utils::Archive::is_decodable_image($empty);
print "空串 -> is_decodable_image = ", (defined $ok ? $ok : 'undef'), " (期望 0/空)\n";

# 从正常页读一个真 JPEG
my $redis = LANraragi::Model::Config->get_redis;
my $path  = LANraragi::Utils::Archive::get_archive_path($redis, $id);
$redis->quit();
print "archive 路径: $path\n";

my $good = LANraragi::Utils::Archive::extract_single_file($path, '0004.jpg');
my $goodlen = defined $good ? length($good) : -1;
my $goodok = LANraragi::Utils::Archive::is_decodable_image($good);
print "0004.jpg 长度=$goodlen -> is_decodable_image=", (defined $goodok ? $goodok : 'undef'), " (期望 1)\n";

my $bad = LANraragi::Utils::Archive::extract_single_file($path, '0001.jpg');
my $badlen = defined $bad ? length($bad) : -1;
my $badok = LANraragi::Utils::Archive::is_decodable_image($bad);
print "0001.jpg 长度=$badlen -> is_decodable_image=", (defined $badok ? $badok : 'undef'), " (期望 0/空)\n";

print "\n=== 2. 对坏图调用 extract_thumbnail（期望被补丁拦下，抛 BROKEN_IMAGE）===\n";
my $r = eval { LANraragi::Utils::Archive::extract_thumbnail($thumbdir, $id, 0, 0, 0); 1 };
if (!$r) {
    print "已被拦截，错误信息: $@\n";
} else {
    print "!!! 未被拦截（补丁可能未生效）\n";
}