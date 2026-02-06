# Android Linux Setup

루팅된 안드로이드 디바이스를 **풀 리눅스 개발환경**으로 만드는 원클릭 셋업.

Termux에서 `setup.sh` 한 번 실행하면:
- chroot 기반 **Ubuntu 22.04** 리눅스 환경 구축
- **Node.js 22** + **Claude Code** 설치
- **SSH** 접속 설정 (키 인증 + 비밀번호)
- 재부팅 후 **자동 시작** (Magisk + Termux:Boot)
- 배터리 최적화/백그라운드 제한 **자동 해제**

## 왜 필요한가?

Termux는 Android 샌드박스 안에서 동작하기 때문에:
- `/tmp` 경로 접근 불가 → Claude Code Task agent 실패
- ripgrep 등 번들 바이너리 호환 문제
- systemd 없음, 표준 리눅스 경로와 다름

**chroot**는 Android 커널 위에 표준 리눅스 파일시스템을 올리는 방식으로:
- `/tmp`이 정상 동작 → Claude Code 100% 호환
- `apt install`로 모든 arm64 리눅스 패키지 사용 가능
- 성능 오버헤드 거의 없음 (VM이 아닌 커널 공유)

## 요구사항

| 항목 | 조건 |
|------|------|
| 디바이스 | Android 12+ (arm64) |
| 루팅 | **필수** (Magisk 또는 KernelSU) |
| Termux | [GitHub releases](https://github.com/termux/termux-app/releases)에서 설치 |
| 저장공간 | 최소 2GB 여유 |
| 네트워크 | 인터넷 연결 필요 (패키지 다운로드) |

## 설치

```bash
# Termux에서 실행
git clone https://github.com/shinjadong/android-linux-setup.git
cd android-linux-setup
bash setup.sh
```

### 환경변수 (선택)

```bash
# SSH 비밀번호 변경 (기본: hi1120)
LINUX_PASSWORD=mypassword bash setup.sh
```

## 사용법

```bash
# 설치 완료 후 새 터미널 열거나:
source ~/.bashrc

# chroot Linux 접속
linux

# chroot에서 Claude Code 바로 실행
lcc

# 직접 SSH
ssh -p 8022 root@localhost
```

## 아키텍처

```
재부팅 흐름:
┌────────────────────────────────────────────┐
│ Android 부팅                                │
│  ├─ Magisk service.d/linux-ssh.sh          │
│  │   └─ chroot 마운트 + DNS + sshd 시작    │
│  ├─ Magisk service.d/bt-fix.sh (선택)      │
│  │   └─ 블루투스 페어링 데이터 자동 초기화   │
│  └─ Termux:Boot                            │
│      └─ termux-wake-lock + sshd 확인       │
└────────────────────────────────────────────┘

사용자: Termux 열기 → linux 입력 → Ubuntu 쉘 진입
```

```
파일시스템:
/data/linux/              ← chroot root
├── bin/, usr/, etc/      ← 표준 리눅스
├── tmp/                  ← Claude Code가 사용 (✓)
├── usr/local/bin/node    ← Node.js 22
├── usr/local/bin/claude  ← Claude Code
└── root/                 ← root 홈

Magisk:
/data/adb/service.d/
├── linux-ssh.sh          ← 부팅 시 chroot + sshd
└── bt-fix.sh             ← 블루투스 자동 수리 (선택)

Termux:
~/.termux/boot/start.sh   ← Termux:Boot 스크립트
~/.bashrc                  ← linux(), lcc() 함수
```

## 설치되는 것들

| 구성요소 | 위치 | 설명 |
|---------|------|------|
| Ubuntu 22.04 chroot | `/data/linux` | debootstrap으로 설치 |
| Node.js 22 | chroot `/usr/local/bin/node` | 공식 arm64 바이너리 |
| Claude Code | chroot `/usr/local/bin/claude` | npm global install |
| SSH 서버 | chroot 포트 8022 | openssh-server |
| Magisk 부팅 스크립트 | `/data/adb/service.d/` | 마운트 + sshd 자동시작 |
| Termux:Boot 앱 | `com.termux.boot` | GitHub APK 자동 설치 |
| Termux:API 앱 | `com.termux.api` | GitHub APK 자동 설치 |
| 배터리/권한 설정 | 시스템 | 배터리 최적화 제외, 백그라운드 허용 |

## /tmp 문제 해결 (핵심)

Claude Code가 Termux에서 `EACCES: permission denied, mkdir '/tmp/claude-*'`로 실패하는 이유:

```
Android /tmp → SELinux 라벨: shell_data_file
Termux 프로세스 → SELinux 도메인: untrusted_app_27
→ SELinux 정책이 untrusted_app의 shell_data_file 쓰기를 차단
→ chmod 1777로도 해결 불가 (DAC는 통과하지만 MAC에서 차단)
```

**해결**: `/tmp`을 `app_data_file` 컨텍스트의 tmpfs로 리마운트

```bash
su -c "umount /tmp; mount -t tmpfs -o mode=1777 tmpfs /tmp; chcon u:object_r:app_data_file:s0 /tmp"
```

이 스크립트는 `fix-tmp.sh`로 Magisk service.d에 설치되어 재부팅마다 자동 적용됩니다.

## Termux vs chroot 비교

| 항목 | Termux | chroot (이 프로젝트) |
|------|--------|---------------------|
| `/tmp` 접근 | ✗ (EACCES) | ✓ |
| Claude Code Task agent | ✗ | ✓ |
| ripgrep | ✗ (ENOENT) | ✓ (`apt install`) |
| apt install | ✗ (pkg 사용) | ✓ |
| 표준 리눅스 경로 | ✗ | ✓ |
| 성능 오버헤드 | 없음 | 거의 없음 (커널 공유) |
| systemd | ✗ | ✗ (Android init 점유) |

## 트러블슈팅

### SSH 접속 안 됨
```bash
# sshd 수동 시작
su -c "chroot /data/linux /usr/sbin/sshd"
# 또는 그냥 linux 명령 (자동 복구)
linux
```

### 마운트 안 됨
```bash
su -c "mount --bind /proc /data/linux/proc"
su -c "mount --bind /sys /data/linux/sys"
su -c "mount --bind /dev /data/linux/dev"
su -c "mount --bind /dev/pts /data/linux/dev/pts"
```

### DNS 안 됨 (apt update 실패)
```bash
# chroot 안에서
echo 'nameserver 8.8.8.8' > /etc/resolv.conf
```

### Termux:Boot/API 설치 실패
F-Droid와 GitHub 서명이 다름. 반드시 **같은 소스**에서 설치:
- Termux가 GitHub에서 설치됨 → 컴패니언 앱도 GitHub releases에서
- Termux가 F-Droid에서 설치됨 → 컴패니언 앱도 F-Droid에서

### Magisk su 알림이 매번 뜸
```bash
su -c "magisk --sqlite \"UPDATE policies SET notification=0\""
```

## 검증된 환경

- Samsung Galaxy Tab S9 FE+ (SM-X826N) / Android 15 / Magisk 29.0

## 라이센스

MIT
