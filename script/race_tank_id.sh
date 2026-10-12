#!/usr/bin/env bash
# 在 lrr 容器内对真实 Redis 做并发铸号测试（修正版：补齐 PERL5LIB）
# 用法（在容器内）：sh /tmp/race_tank_id.sh
set -uo pipefail

export PERL5LIB="/home/koyomi/lanraragi/lib:/home/koyomi/perl5/lib/perl5"
cd /home/koyomi/lanraragi

echo "=== 铸号前 counter ==="
valkey-cli -n 0 get LRR_TANK_ID_SEQ
echo "(空=从未用过，符合预期)"

echo
echo "=== 8 个进程并发调用 create_tankoubon() ==="
rm -f /tmp/race_out_*.txt
for i in 1 2 3 4 5 6 7 8; do
    (
        perl -Ilib -I/home/koyomi/perl5/lib/perl5 \
            -MLANraragi::Model::Tankoubon=create_tankoubon -e '
            my $id = create_tankoubon( "RealRace'"$i"'", "" );
            print "$id\n";
        ' > "/tmp/race_out_$i.txt" 2>&1
    ) &
done
wait

echo
echo "=== 各进程输出 ==="
cat /tmp/race_out_*.txt

echo
echo "=== 去重判定（只看形如 TANK_数字 的行）==="
cat /tmp/race_out_*.txt | grep -E '^TANK_[0-9]+$' | sort > /tmp/race_all.txt
total=$(wc -l < /tmp/race_all.txt)
uniq=$(sort -u /tmp/race_all.txt | wc -l)
echo "有效 id 总数=$total  去重后=$uniq"
if [ "$total" -eq 8 ] && [ "$uniq" -eq 8 ]; then
    echo "RESULT: PASS —— 8 个并发进程铸出 8 个互不相同的 id"
else
    echo "RESULT: FAIL"
    [ "$total" -ne 8 ] && echo "  (有效 id 数不是 8，说明有进程报错)"
    [ "$uniq" -ne "$total" ] && echo "  重复 id:" && sort /tmp/race_all.txt | uniq -d
fi

echo
echo "=== 铸号后 counter ==="
valkey-cli -n 0 get LRR_TANK_ID_SEQ

echo
echo "=== 实际写入的 TANK_ key ==="
valkey-cli -n 0 --scan --pattern 'TANK_*' 2>/dev/null | grep -E 'TANK_179' | head -20

echo
echo "=== 清理测试 tank ==="
if [ -s /tmp/race_all.txt ]; then
    while read -r id; do
        [ -n "$id" ] && valkey-cli -n 0 del "$id" > /dev/null
    done < /tmp/race_all.txt
fi
rm -f /tmp/race_out_*.txt /tmp/race_all.txt
echo "cleanup done"