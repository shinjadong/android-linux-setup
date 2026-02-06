#!/data/data/com.termux/files/usr/bin/bash
# Termux:Boot — 부팅 시 자동 실행

# 백그라운드 kill 방지
termux-wake-lock

# Termux 자체 sshd (포트 8023, chroot 8022와 충돌 방지)
sshd -p 8023 2>/dev/null

# chroot sshd 살아있는지 확인, 없으면 시작
if ! ssh -o ConnectTimeout=3 -o BatchMode=yes -p 8022 root@localhost true 2>/dev/null; then
  su -c "chroot /data/linux /usr/sbin/sshd" 2>/dev/null
fi
