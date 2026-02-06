#!/system/bin/sh
# Linux chroot 자동 시작 (Magisk service.d)
# 부팅 → 네트워크 대기 → 마운트 → DNS → sshd

LOG=/data/local/tmp/linux-ssh.log

log() { echo "$(date '+%m-%d %H:%M:%S'): $1" >> $LOG; }

log '=== Boot trigger ==='

# 네트워크 대기 (최대 60초)
for i in $(seq 1 12); do
  ping -c1 -W2 8.8.8.8 >/dev/null 2>&1 && break
  sleep 5
done

LINUX=/data/linux

# 마운트 (중복 방지)
mountpoint -q $LINUX/proc    || mount --bind /proc $LINUX/proc
mountpoint -q $LINUX/sys     || mount --bind /sys $LINUX/sys
mountpoint -q $LINUX/dev     || mount --bind /dev $LINUX/dev
mountpoint -q $LINUX/dev/pts || mount --bind /dev/pts $LINUX/dev/pts

# /storage 마운트 (Android 공유 스토리지)
mkdir -p $LINUX/mnt/sdcard
mountpoint -q $LINUX/mnt/sdcard || mount --bind /data/media/0 $LINUX/mnt/sdcard 2>/dev/null

# tmp, run
mkdir -p $LINUX/tmp $LINUX/run/sshd
chmod 1777 $LINUX/tmp

# DNS
echo 'nameserver 8.8.8.8' > $LINUX/etc/resolv.conf
echo 'nameserver 1.1.1.1' >> $LINUX/etc/resolv.conf

# sshd 시작 (이미 떠있으면 스킵)
if ! chroot $LINUX /bin/bash -c 'export PATH=/usr/sbin:/usr/bin:/sbin:/bin; pgrep -x sshd' >/dev/null 2>&1; then
  chroot $LINUX /usr/sbin/sshd
  log 'sshd started'
else
  log 'sshd already running'
fi

log 'Boot complete'
