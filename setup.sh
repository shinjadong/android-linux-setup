#!/data/data/com.termux/files/usr/bin/bash
set -e

# ============================================================
# Android Linux Setup — 루팅된 안드로이드를 풀 리눅스 개발환경으로
# 한 번 실행하면: chroot Linux + Node.js 22 + Claude Code + SSH
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINUX_ROOT="/data/linux"
SSH_PORT=8022
SSH_PASSWORD="${LINUX_PASSWORD:-hi1120}"
NODE_VERSION="22.13.1"

# --- Colors ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

info()  { echo -e "${CYAN}[*]${NC} $1"; }
ok()    { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
fail()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# ============================================================
# Step 0: Prerequisites
# ============================================================
echo ""
echo -e "${CYAN}═══════════════════════════════════════════${NC}"
echo -e "${CYAN}  Android Linux Setup${NC}"
echo -e "${CYAN}═══════════════════════════════════════════${NC}"
echo ""

info "Prerequisites 확인..."

# Root check
if ! su -c "id" >/dev/null 2>&1; then
  fail "루팅 필요! Magisk 또는 KernelSU가 설치되어 있어야 합니다."
fi
ok "루트 접근 확인"

# Magisk check
MAGISK_VER=$(su -c "magisk -v" 2>/dev/null || echo "none")
if [ "$MAGISK_VER" = "none" ]; then
  warn "Magisk 미감지 (KernelSU 등 다른 루트 솔루션 사용 중?)"
else
  ok "Magisk $MAGISK_VER 감지"
fi

# Device info
MODEL=$(getprop ro.product.model 2>/dev/null || echo "Unknown")
ANDROID_VER=$(getprop ro.build.version.release 2>/dev/null || echo "?")
info "디바이스: $MODEL (Android $ANDROID_VER)"

# ============================================================
# Step 1: Linux chroot 설치 (없으면)
# ============================================================
echo ""
info "Step 1: Linux chroot 환경 확인..."

if [ -f "$LINUX_ROOT/bin/bash" ]; then
  ok "Linux chroot 이미 존재 ($LINUX_ROOT)"
else
  info "Ubuntu 22.04 arm64 chroot 설치 중... (시간 소요)"

  # debootstrap 설치
  pkg install -y debootstrap 2>/dev/null || true

  su -c "mkdir -p $LINUX_ROOT"

  # debootstrap으로 최소 Ubuntu 설치
  su -c "debootstrap --arch=arm64 jammy $LINUX_ROOT http://ports.ubuntu.com/ubuntu-ports" 2>&1 | tail -5

  if [ ! -f "$LINUX_ROOT/bin/bash" ]; then
    fail "chroot 설치 실패"
  fi
  ok "Ubuntu 22.04 chroot 설치 완료"
fi

# ============================================================
# Step 2: chroot 마운트
# ============================================================
info "Step 2: chroot 마운트..."

su -c "mountpoint -q $LINUX_ROOT/proc  || mount --bind /proc $LINUX_ROOT/proc"
su -c "mountpoint -q $LINUX_ROOT/sys   || mount --bind /sys $LINUX_ROOT/sys"
su -c "mountpoint -q $LINUX_ROOT/dev   || mount --bind /dev $LINUX_ROOT/dev"
su -c "mountpoint -q $LINUX_ROOT/dev/pts || mount --bind /dev/pts $LINUX_ROOT/dev/pts"
su -c "mkdir -p $LINUX_ROOT/tmp $LINUX_ROOT/run/sshd && chmod 1777 $LINUX_ROOT/tmp"

# /storage 마운트 (Android 공유 스토리지 접근)
su -c "mkdir -p $LINUX_ROOT/mnt/sdcard"
su -c "mountpoint -q $LINUX_ROOT/mnt/sdcard || mount --bind /data/media/0 $LINUX_ROOT/mnt/sdcard" 2>/dev/null || true

# DNS
su -c "echo 'nameserver 8.8.8.8' > $LINUX_ROOT/etc/resolv.conf"
su -c "echo 'nameserver 1.1.1.1' >> $LINUX_ROOT/etc/resolv.conf"

ok "마운트 완료"

# ============================================================
# Step 3: chroot 기본 설정 + 개발 환경
# ============================================================
info "Step 3: chroot 내부 기본 설정 + 개발 환경..."

# apt sources.list 확장 (universe/multiverse 포함)
su -c "cat > $LINUX_ROOT/etc/apt/sources.list << 'SRCEOF'
deb http://ports.ubuntu.com/ubuntu-ports jammy main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports jammy-updates main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports jammy-security main restricted universe multiverse
SRCEOF"

su -c "cat > $LINUX_ROOT/tmp/chroot-base-setup.sh << 'INNEREOF'
#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive
export HOME=/root

# 패키지 설치 (기본 + 개발 도구)
apt-get update -qq 2>/dev/null
apt-get install -y \
  openssh-server curl ca-certificates wget \
  git ripgrep jq tmux htop \
  build-essential locales vim nano \
  2>&1 | tail -5

# Locale 설정 (ko_KR.UTF-8 + en_US.UTF-8)
sed -i 's/# ko_KR.UTF-8/ko_KR.UTF-8/' /etc/locale.gen
sed -i 's/# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen 2>&1 | tail -3
update-locale LANG=ko_KR.UTF-8 LC_ALL=ko_KR.UTF-8

# Timezone: Asia/Seoul
ln -sf /usr/share/zoneinfo/Asia/Seoul /etc/localtime
echo 'Asia/Seoul' > /etc/timezone

# /etc/environment (비로그인 쉘용)
cat > /etc/environment << 'ENVEOF'
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
LANG=ko_KR.UTF-8
LC_ALL=ko_KR.UTF-8
ENVEOF

# /etc/profile.d/ (로그인 쉘용 — bash -lc 에서도 작동)
cat > /etc/profile.d/chroot-env.sh << 'PROFEOF'
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LANG=ko_KR.UTF-8
export LC_ALL=ko_KR.UTF-8
export HOME=/root
export EDITOR=vim
PROFEOF
chmod 644 /etc/profile.d/chroot-env.sh

# Git 기본 설정 (HOME이 /root가 아닐 수 있으므로 경로 명시)
git config --file /root/.gitconfig init.defaultBranch main
git config --file /root/.gitconfig core.editor vim

echo 'BASE_SETUP_DONE'
INNEREOF
chmod 755 $LINUX_ROOT/tmp/chroot-base-setup.sh"

RESULT=$(su -c "chroot $LINUX_ROOT /bin/bash /tmp/chroot-base-setup.sh 2>&1 | tail -1")
if [ "$RESULT" = "BASE_SETUP_DONE" ]; then
  ok "기본 패키지 + 개발 환경 설치 완료"
else
  warn "기본 설정 중 문제 발생 (계속 진행)"
fi

# Git user config (환경변수로 오버라이드 가능)
GIT_USER="${GIT_USERNAME:-}"
GIT_EMAIL="${GIT_USEREMAIL:-}"
if [ -n "$GIT_USER" ]; then
  su -c "chroot $LINUX_ROOT /bin/bash -lc 'git config --file /root/.gitconfig user.name \"$GIT_USER\"'"
  su -c "chroot $LINUX_ROOT /bin/bash -lc 'git config --file /root/.gitconfig user.email \"${GIT_EMAIL:-${GIT_USER}@users.noreply.github.com}\"'"
  ok "Git config: $GIT_USER"
fi

# ============================================================
# Step 4: Node.js 22 설치
# ============================================================
echo ""
info "Step 4: Node.js $NODE_VERSION 설치..."

NODE_CHECK=$(su -c "chroot $LINUX_ROOT /bin/bash -c 'export PATH=/usr/local/bin:/usr/bin:/bin; node --version 2>/dev/null || echo NONE'")

if [ "$NODE_CHECK" = "v$NODE_VERSION" ]; then
  ok "Node.js $NODE_CHECK 이미 설치됨"
else
  su -c "cat > $LINUX_ROOT/tmp/install-node.sh << 'INNEREOF'
#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
cd /tmp
curl -fsSL https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-arm64.tar.gz -o node.tar.gz
tar -xzf node.tar.gz
cp -r node-v${NODE_VERSION}-linux-arm64/bin/* /usr/local/bin/
cp -r node-v${NODE_VERSION}-linux-arm64/lib/* /usr/local/lib/
cp -r node-v${NODE_VERSION}-linux-arm64/include/* /usr/local/include/ 2>/dev/null
cp -r node-v${NODE_VERSION}-linux-arm64/share/* /usr/local/share/ 2>/dev/null
rm -rf /tmp/node.tar.gz /tmp/node-v*
node --version
INNEREOF
  chmod 755 $LINUX_ROOT/tmp/install-node.sh"

  # Variable substitution in heredoc needs to happen before writing
  su -c "sed -i 's/\${NODE_VERSION}/$NODE_VERSION/g' $LINUX_ROOT/tmp/install-node.sh"

  NODE_RESULT=$(su -c "chroot $LINUX_ROOT /bin/bash /tmp/install-node.sh 2>&1 | tail -1")
  if echo "$NODE_RESULT" | grep -q "v$NODE_VERSION"; then
    ok "Node.js $NODE_RESULT 설치 완료"
  else
    fail "Node.js 설치 실패: $NODE_RESULT"
  fi
fi

# ============================================================
# Step 5: Claude Code 설치
# ============================================================
info "Step 5: Claude Code 설치..."

CLAUDE_CHECK=$(su -c "chroot $LINUX_ROOT /bin/bash -c 'export PATH=/usr/local/bin:/usr/bin:/bin; claude --version 2>/dev/null || echo NONE'" | head -1)

if echo "$CLAUDE_CHECK" | grep -q "Claude Code"; then
  ok "Claude Code 이미 설치됨 ($CLAUDE_CHECK)"
else
  su -c "chroot $LINUX_ROOT /bin/bash -c 'export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin && npm install -g @anthropic-ai/claude-code --prefix /usr/local'" 2>&1 | tail -5

  CLAUDE_VER=$(su -c "chroot $LINUX_ROOT /bin/bash -c 'export PATH=/usr/local/bin:/usr/bin:/bin; claude --version 2>/dev/null || echo NONE'" | head -1)
  if echo "$CLAUDE_VER" | grep -q "Claude Code"; then
    ok "Claude Code 설치 완료 ($CLAUDE_VER)"
  else
    warn "Claude Code 설치 실패 — 수동 설치 필요"
  fi
fi

# ============================================================
# Step 6: SSH 설정
# ============================================================
echo ""
info "Step 6: SSH 설정 (포트 $SSH_PORT)..."

su -c "cat > $LINUX_ROOT/tmp/setup-ssh.sh << 'INNEREOF'
#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# root 비밀번호 설정
echo \"root:SSH_PASSWORD_PLACEHOLDER\" | chpasswd

# sshd 설정
sed -i 's/^#*Port .*/Port SSH_PORT_PLACEHOLDER/' /etc/ssh/sshd_config
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config

# SSH 키 복사 (Termux 키가 있으면)
mkdir -p /root/.ssh
chmod 700 /root/.ssh
if [ -f /proc/1/../data/data/com.termux/files/home/.ssh/id_rsa.pub ]; then
  cat /proc/1/../data/data/com.termux/files/home/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
fi

# sshd 재시작
kill \$(cat /run/sshd.pid 2>/dev/null) 2>/dev/null || true
/usr/sbin/sshd
echo SSH_DONE
INNEREOF
chmod 755 $LINUX_ROOT/tmp/setup-ssh.sh"

su -c "sed -i 's/SSH_PASSWORD_PLACEHOLDER/$SSH_PASSWORD/g' $LINUX_ROOT/tmp/setup-ssh.sh"
su -c "sed -i 's/SSH_PORT_PLACEHOLDER/$SSH_PORT/g' $LINUX_ROOT/tmp/setup-ssh.sh"

SSH_RESULT=$(su -c "chroot $LINUX_ROOT /bin/bash /tmp/setup-ssh.sh 2>&1 | tail -1")
if [ "$SSH_RESULT" = "SSH_DONE" ]; then
  ok "SSH 설정 완료 (포트: $SSH_PORT, 비밀번호: $SSH_PASSWORD)"
else
  warn "SSH 설정 중 문제 발생"
fi

# SSH 키 권한 수정
chmod 600 ~/.ssh/id_rsa 2>/dev/null

# ============================================================
# Step 7: Magisk 부팅 스크립트
# ============================================================
echo ""
info "Step 7: Magisk 부팅 스크립트 설치..."

if su -c "magisk -v" >/dev/null 2>&1; then
  su -c "cp $SCRIPT_DIR/configs/linux-ssh.sh /data/adb/service.d/linux-ssh.sh && chmod 755 /data/adb/service.d/linux-ssh.sh"
  ok "Magisk service.d/linux-ssh.sh 설치"

  # /tmp 권한 수정 (Claude Code EACCES 해결)
  su -c "cp $SCRIPT_DIR/configs/fix-tmp.sh /data/adb/service.d/fix-tmp.sh && chmod 755 /data/adb/service.d/fix-tmp.sh"
  ok "Magisk service.d/fix-tmp.sh 설치 (/tmp SELinux 수정)"

  # 즉시 적용
  su -c "umount /tmp 2>/dev/null; mount -t tmpfs -o mode=1777 tmpfs /tmp && chcon u:object_r:app_data_file:s0 /tmp && chmod 1777 /tmp" 2>/dev/null
  ok "/tmp 즉시 수정 적용"

  # bt-fix는 선택적
  if [ -f "$SCRIPT_DIR/configs/bt-fix.sh" ]; then
    su -c "cp $SCRIPT_DIR/configs/bt-fix.sh /data/adb/service.d/bt-fix.sh && chmod 755 /data/adb/service.d/bt-fix.sh"
    ok "Magisk service.d/bt-fix.sh 설치 (블루투스 자동 수리)"
  fi

  # su 알림 비활성화
  su -c "magisk --sqlite \"UPDATE policies SET notification=0\" 2>/dev/null" && ok "Magisk su 알림 비활성화"
else
  warn "Magisk 미감지 — 부팅 스크립트 수동 설치 필요"
fi

# ============================================================
# Step 8: Termux:Boot & API 앱 설치
# ============================================================
echo ""
info "Step 8: Termux 컴패니언 앱 설치..."

BOOT_INSTALLED=$(pm list packages 2>/dev/null | grep "com.termux.boot" || true)
API_INSTALLED=$(pm list packages 2>/dev/null | grep "com.termux.api" || true)

install_apk() {
  local name=$1 url=$2 pkg=$3
  if pm list packages 2>/dev/null | grep -q "$pkg"; then
    ok "$name 이미 설치됨"
    return
  fi

  info "$name 다운로드 중..."
  curl -fsSL -L -o "$PREFIX/tmp/${name}.apk" "$url" 2>/dev/null

  if [ -f "$PREFIX/tmp/${name}.apk" ] && [ "$(stat -c%s "$PREFIX/tmp/${name}.apk" 2>/dev/null || echo 0)" -gt 50000 ]; then
    su -c "cp $PREFIX/tmp/${name}.apk /data/local/tmp/${name}.apk && chmod 644 /data/local/tmp/${name}.apk && pm install -r --bypass-low-target-sdk-block /data/local/tmp/${name}.apk" 2>&1
    if pm list packages 2>/dev/null | grep -q "$pkg"; then
      ok "$name 설치 완료"
    else
      warn "$name 설치 실패 — F-Droid에서 수동 설치 필요"
    fi
    su -c "rm -f /data/local/tmp/${name}.apk"
    rm -f "$PREFIX/tmp/${name}.apk"
  else
    warn "$name 다운로드 실패"
  fi
}

install_apk "termux-boot" \
  "https://github.com/termux/termux-boot/releases/download/v0.8.1/termux-boot-app_v0.8.1+github.debug.apk" \
  "com.termux.boot"

install_apk "termux-api" \
  "https://github.com/termux/termux-api/releases/download/v0.53.0/termux-api-app_v0.53.0+github.debug.apk" \
  "com.termux.api"

# Termux:Boot 스크립트 설치
mkdir -p ~/.termux/boot
cp "$SCRIPT_DIR/configs/termux-boot-start.sh" ~/.termux/boot/start.sh
chmod 755 ~/.termux/boot/start.sh
ok "Termux:Boot 스크립트 설치"

# Termux:Boot 초기 실행 (등록)
su -c "am start -n com.termux.boot/.BootActivity" 2>/dev/null && ok "Termux:Boot 활성화"

# ============================================================
# Step 9: 시스템 권한 설정
# ============================================================
echo ""
info "Step 9: 시스템 권한 설정..."

# 배터리 최적화 제외
for pkg in com.termux com.termux.boot com.termux.api; do
  su -c "dumpsys deviceidle whitelist +$pkg" 2>/dev/null
done
ok "배터리 최적화 제외"

# 백그라운드 실행 허용
for pkg in com.termux com.termux.boot com.termux.api; do
  su -c "cmd appops set $pkg RUN_IN_BACKGROUND allow" 2>/dev/null
  su -c "cmd appops set $pkg RUN_ANY_IN_BACKGROUND allow" 2>/dev/null
done
ok "백그라운드 실행 허용"

# Standby bucket = ACTIVE
for pkg in com.termux com.termux.boot com.termux.api; do
  su -c "am set-standby-bucket $pkg active" 2>/dev/null
done
ok "Standby bucket ACTIVE 설정"

# ============================================================
# Step 10: Android 명령어 브릿지 (nsenter wrappers)
# ============================================================
echo ""
info "Step 10: chroot에서 Android 명령어 사용 설정..."

su -c "cat > $LINUX_ROOT/tmp/install-nsenter-wrappers.sh << 'INNEREOF'
#!/bin/bash
# chroot 안에서 Android 명령어를 쓸 수 있게 nsenter wrapper 설치
# nsenter -t 1 -m: PID 1 (Android init)의 마운트 네임스페이스로 진입

CMDS="pm am settings dumpsys cmd getprop setprop input svc"

for cmd in \$CMDS; do
  cat > /usr/local/bin/\$cmd << WRAPEOF
#!/bin/bash
nsenter -t 1 -m -- /system/bin/\$cmd "\\\$@"
WRAPEOF
  chmod 755 /usr/local/bin/\$cmd
done

# android — 일반 Android 명령 실행
cat > /usr/local/bin/android << 'WRAPEOF'
#!/bin/bash
# Android 명령 실행 (chroot에서 Android 네임스페이스로 진입)
nsenter -t 1 -m -- "$@"
WRAPEOF
chmod 755 /usr/local/bin/android

# asu — Android 쪽 root shell
cat > /usr/local/bin/asu << 'WRAPEOF'
#!/bin/bash
# Android su — chroot에서 Android 쪽 root 명령 실행
nsenter -t 1 -m -- /system/bin/sh -c "$*"
WRAPEOF
chmod 755 /usr/local/bin/asu

echo NSENTER_DONE
INNEREOF
chmod 755 $LINUX_ROOT/tmp/install-nsenter-wrappers.sh"

NSENTER_RESULT=$(su -c "chroot $LINUX_ROOT /bin/bash /tmp/install-nsenter-wrappers.sh 2>&1 | tail -1")
if [ "$NSENTER_RESULT" = "NSENTER_DONE" ]; then
  ok "Android 명령어 브릿지 설치 (pm, am, settings, dumpsys 등)"
else
  warn "nsenter wrapper 설치 중 문제 발생 (계속 진행)"
fi

# ============================================================
# Step 11: Fake ADB wrapper (on-device automation)
# ============================================================
echo ""
info "Step 11: ADB wrapper 설치 (디바이스 자체 자동화용)..."

su -c "cat > $LINUX_ROOT/usr/local/bin/adb << 'ADBWRAP'
#!/bin/bash
# Fake ADB wrapper — translates adb shell to nsenter for on-device use
ARGS=(\"\$@\"); IDX=0
[[ \"\${ARGS[0]}\" == \"-s\" ]] && IDX=2
CMD=\"\${ARGS[\$IDX]}\"
case \"\$CMD\" in
    devices) echo \"List of devices attached\"; echo \"\$(nsenter -t 1 -m -- getprop ro.serialno 2>/dev/null || echo localhost)\tdevice\" ;;
    get-state) echo \"device\" ;;
    shell) nsenter -t 1 -m -- /system/bin/sh -c \"\${ARGS[*]:\$((IDX+1))}\" ;;
    forward) echo \"forward: not fully supported in on-device mode\" >&2 ;;
    *) echo \"adb wrapper: unsupported '\$CMD'\" >&2; exit 1 ;;
esac
ADBWRAP
chmod 755 $LINUX_ROOT/usr/local/bin/adb"
ok "ADB wrapper 설치"

# ============================================================
# Step 12: code-server (브라우저 VS Code)
# ============================================================
echo ""
info "Step 12: code-server 설치..."

CODE_SERVER_CHECK=$(su -c "chroot $LINUX_ROOT /bin/bash -lc 'which code-server 2>/dev/null || echo NONE'")
if [ "$CODE_SERVER_CHECK" != "NONE" ]; then
  ok "code-server 이미 설치됨"
else
  su -c "chroot $LINUX_ROOT /bin/bash -lc 'curl -fsSL https://code-server.dev/install.sh | sh'" 2>&1 | tail -5
  ok "code-server 설치 완료"
fi

# code-server 설정
su -c "mkdir -p $LINUX_ROOT/root/.config/code-server"
su -c "cat > $LINUX_ROOT/root/.config/code-server/config.yaml << 'CSEOF'
bind-addr: 0.0.0.0:8080
auth: password
password: CS_PASSWORD_PLACEHOLDER
cert: false
CSEOF"
su -c "sed -i 's/CS_PASSWORD_PLACEHOLDER/$SSH_PASSWORD/g' $LINUX_ROOT/root/.config/code-server/config.yaml"
ok "code-server 설정 (포트 8080, 비밀번호: $SSH_PASSWORD)"

# code-server 익스텐션 설치
info "code-server 익스텐션 설치 중..."
su -c "chroot $LINUX_ROOT /bin/bash -lc '
code-server --install-extension ms-python.python 2>/dev/null
code-server --install-extension dbaeumer.vscode-eslint 2>/dev/null
code-server --install-extension esbenp.prettier-vscode 2>/dev/null
code-server --install-extension eamodio.gitlens 2>/dev/null
code-server --install-extension PKief.material-icon-theme 2>/dev/null
code-server --install-extension dracula-theme.theme-dracula 2>/dev/null
code-server --install-extension redhat.vscode-yaml 2>/dev/null
'" 2>&1 | tail -3
ok "code-server 익스텐션 설치 (Python, ESLint, Prettier, GitLens, Dracula 등)"

# code-server 기본 설정 (Dracula 테마, 자동저장, 태블릿 최적화)
su -c "mkdir -p $LINUX_ROOT/root/.local/share/code-server/User"
su -c "cat > $LINUX_ROOT/root/.local/share/code-server/User/settings.json << 'SETTINGSEOF'
{
    \"workbench.colorTheme\": \"Dracula\",
    \"workbench.iconTheme\": \"material-icon-theme\",
    \"editor.fontSize\": 14,
    \"editor.tabSize\": 2,
    \"editor.wordWrap\": \"on\",
    \"editor.minimap.enabled\": false,
    \"terminal.integrated.fontSize\": 13,
    \"terminal.integrated.defaultProfile.linux\": \"bash\",
    \"files.autoSave\": \"afterDelay\",
    \"files.autoSaveDelay\": 1000,
    \"python.defaultInterpreterPath\": \"/usr/bin/python3\",
    \"editor.bracketPairColorization.enabled\": true,
    \"workbench.startupEditor\": \"none\"
}
SETTINGSEOF"
ok "code-server 설정 (Dracula 테마, 자동저장, 태블릿 최적화)"

echo -e "  ${CYAN}브라우저에서 http://localhost:8080 접속${NC}"

# ============================================================
# Step 13: Hacker's Keyboard (PC 레이아웃 키보드)
# ============================================================
echo ""
info "Step 13: Hacker's Keyboard 설치..."

if pm list packages 2>/dev/null | grep -q "org.pocketworkstation.pckeyboard"; then
  ok "Hacker's Keyboard 이미 설치됨"
else
  HK_APK="$PREFIX/tmp/hackerskb.apk"
  curl -fsSL -L -o "$HK_APK" "https://f-droid.org/repo/org.pocketworkstation.pckeyboard_1041001.apk" 2>/dev/null
  if [ -f "$HK_APK" ] && [ "$(stat -c%s "$HK_APK" 2>/dev/null || echo 0)" -gt 50000 ]; then
    su -c "cp $HK_APK /data/local/tmp/hackerskb.apk && chmod 644 /data/local/tmp/hackerskb.apk && pm install -r /data/local/tmp/hackerskb.apk" 2>&1
    if pm list packages 2>/dev/null | grep -q "org.pocketworkstation.pckeyboard"; then
      ok "Hacker's Keyboard 설치 완료"
    else
      warn "Hacker's Keyboard 설치 실패 — F-Droid에서 수동 설치"
    fi
    su -c "rm -f /data/local/tmp/hackerskb.apk"
    rm -f "$HK_APK"
  else
    warn "Hacker's Keyboard 다운로드 실패"
  fi
fi

# ============================================================
# Step 14: chroot 쉘 환경 + CLAUDE.md
# ============================================================
echo ""
info "Step 14: chroot 쉘 환경 설정..."

# chroot .bashrc 설치
su -c "cat > $LINUX_ROOT/root/.bashrc << 'CHROOTBASHRC'
# ~/.bashrc — Android Linux Setup (chroot)
[ -z \"\\\$PS1\" ] && return

# History
HISTCONTROL=ignoredups:ignorespace
HISTSIZE=5000
HISTFILESIZE=10000
shopt -s histappend
shopt -s checkwinsize
shopt -s cdspell 2>/dev/null

# Environment
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root
export LANG=ko_KR.UTF-8
export LC_ALL=ko_KR.UTF-8
export EDITOR=vim
export TERM=xterm-256color

# Prompt (chroot indicator)
PS1='\\[\\033[1;36m\\][chroot]\\[\\033[0m\\] \\[\\033[1;32m\\]\\u\\[\\033[0m\\]:\\[\\033[1;34m\\]\\w\\[\\033[0m\\]\\$ '

# Colors
if [ -x /usr/bin/dircolors ]; then
    eval \"\\\$(dircolors -b)\"
    alias ls='ls --color=auto'
    alias grep='grep --color=auto'
fi

# Aliases
alias ll='ls -alFh'
alias la='ls -A'
alias l='ls -CF'
alias ..='cd ..'
alias ...='cd ../..'
alias gs='git status'
alias gl='git log --oneline -20'
alias gd='git diff'
alias vault='cd /mnt/sdcard/Documents/Brain'
alias sdcard='cd /mnt/sdcard'
alias cc='claude'

# Bash completion
if [ -f /etc/bash_completion ] && ! shopt -oq posix; then
    . /etc/bash_completion
fi

cd /root
CHROOTBASHRC"
ok "chroot .bashrc 설치"

# CLAUDE.md + rules 복사 (Termux에서 있으면)
TERMUX_HOME="/data/data/com.termux/files/home"
su -c "mkdir -p $LINUX_ROOT/root/.claude/rules"
if [ -f "$TERMUX_HOME/.claude/CLAUDE.md" ]; then
  su -c "cp $TERMUX_HOME/.claude/CLAUDE.md $LINUX_ROOT/root/.claude/CLAUDE.md"
  ok "CLAUDE.md 복사"
fi
for f in "$TERMUX_HOME/.claude/rules/"*; do
  [ -f "$f" ] && su -c "cp $f $LINUX_ROOT/root/.claude/rules/"
done
ok "Claude rules 복사"

# Obsidian vault 심볼릭 링크
su -c "ln -sf /mnt/sdcard/Documents/Brain $LINUX_ROOT/root/vault" 2>/dev/null
ok "~/vault → Obsidian Brain 링크"

# ============================================================
# Step 15: Termux .bashrc 설정
# ============================================================
echo ""
info "Step 15: 쉘 바로가기 설정..."

# linux 함수가 이미 있으면 스킵
if grep -q "function linux\|linux()" ~/.bashrc 2>/dev/null; then
  ok ".bashrc에 linux 함수 이미 존재"
else
  cat >> ~/.bashrc << 'BASHEOF'

# ====== Android Linux Setup ======
# chroot Linux 한방 접속 (sshd 죽어있으면 자동 복구)
linux() {
  if ! ssh -o ConnectTimeout=2 -o BatchMode=yes -p 8022 root@localhost true 2>/dev/null; then
    echo "chroot sshd 시작 중..."
    su -c "mountpoint -q /data/linux/proc || mount --bind /proc /data/linux/proc" 2>/dev/null
    su -c "mountpoint -q /data/linux/sys || mount --bind /sys /data/linux/sys" 2>/dev/null
    su -c "mountpoint -q /data/linux/dev || mount --bind /dev /data/linux/dev" 2>/dev/null
    su -c "mountpoint -q /data/linux/dev/pts || mount --bind /dev/pts /data/linux/dev/pts" 2>/dev/null
    su -c "mkdir -p /data/linux/tmp /data/linux/run/sshd /data/linux/mnt/sdcard && chmod 1777 /data/linux/tmp" 2>/dev/null
    su -c "mountpoint -q /data/linux/mnt/sdcard || mount --bind /data/media/0 /data/linux/mnt/sdcard" 2>/dev/null
    su -c "chroot /data/linux /usr/sbin/sshd" 2>/dev/null
    sleep 1
  fi
  ssh -p 8022 root@localhost "$@"
}
lcc() { linux -t claude "$@"; }
BASHEOF
  ok ".bashrc에 linux/lcc 함수 추가"
fi

# ============================================================
# Done!
# ============================================================
echo ""
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo -e "${GREEN}  설치 완료!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo ""
echo -e "  ${CYAN}linux${NC}       chroot Linux 쉘 접속"
echo -e "  ${CYAN}lcc${NC}         chroot에서 Claude Code 바로 실행"
echo -e "  ${CYAN}ssh -p $SSH_PORT root@localhost${NC}"
echo ""
echo -e "  SSH 비밀번호:  ${YELLOW}$SSH_PASSWORD${NC}"
echo -e "  chroot 경로:  $LINUX_ROOT"
echo -e "  Node.js:      v$NODE_VERSION"
echo -e "  code-server:  ${CYAN}http://localhost:8080${NC}"
echo ""
echo -e "  ${YELLOW}새 터미널에서 'source ~/.bashrc' 또는 재시작 후 사용${NC}"
echo ""
