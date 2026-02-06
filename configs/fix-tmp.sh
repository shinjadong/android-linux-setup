#!/system/bin/sh
# /tmp을 모든 앱이 쓸 수 있게 리마운트 (Magisk service.d)
#
# 문제: Android의 /tmp은 SELinux 라벨이 shell_data_file이라
#       Termux(untrusted_app)에서 쓰기 불가 → Claude Code EACCES
# 해결: tmpfs를 app_data_file 컨텍스트로 리마운트

sleep 5

umount /tmp 2>/dev/null
mount -t tmpfs -o mode=1777,uid=0,gid=0 tmpfs /tmp
chcon u:object_r:app_data_file:s0 /tmp
chmod 1777 /tmp

echo "$(date): /tmp fixed (app_data_file)" >> /data/local/tmp/fix-tmp.log
