#!/usr/bin/env perl
# bench_http.pl -- time the /api/archives endpoint from inside the container,
# using Time::HiRes so we are not fooled by the broken `date +%s%N`.
use strict;
use warnings;
use Time::HiRes qw(time);
use IO::Socket::INET;

my @paths = (
    '/api/archives?start=0',
    '/api/archives?start=75000',
    '/api/archives?start=150600',
);

for my $p (@paths) {
    my $t0 = time;
    my $sock = IO::Socket::INET->new(
        PeerHost => '127.0.0.1',
        PeerPort => 3000,
        Proto    => 'tcp',
        Timeout  => 30,
    ) or die "connect failed: $!";

    print $sock "GET $p HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";

    my $body   = '';
    local $/;
    $body = <$sock>;
    close $sock;
    my $t1 = time;

    my ($status) = $body =~ m{HTTP/1\.1 (\d+)};
    my $bytes   = length($body);
    my $entries = () = $body =~ /"arcid"/g;

    printf "%-28s %6.1f ms  status=%s  bytes=%d  entries=%d\n",
        $p, ($t1 - $t0) * 1000, $status // '?', $bytes, $entries;
}