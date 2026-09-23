#!/bin/sh
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH
export PATH

usage() {
    echo "Usage: $0 debian|alpine --ssh-key 'ssh-ed25519 ...'" >&2
    exit 1
}

[ "$#" -eq 3 ] && [ "$2" = --ssh-key ] && [ -n "$3" ] || usage
DISTRO=$1
SSH_KEY=$3
case "$DISTRO" in debian|alpine) ;; *) usage ;; esac
case "$SSH_KEY" in ssh-*|ecdsa-*|sk-*) ;; *) echo 'Expected an SSH public key' >&2; exit 1 ;; esac
[ "$(id -u)" -eq 0 ] || { echo 'Run as root inside the container' >&2; exit 1; }
if ! grep -aq 'container=lxc' /proc/1/environ &&
   [ ! -S /dev/incus/sock ] && [ ! -S /dev/lxd/sock ]; then
    echo 'Only Incus/LXC system containers are supported' >&2
    exit 1
fi

for command in curl tar mount umount chroot awk cp hostname; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "Missing prerequisite: $command" >&2; exit 1;
    }
done
SSH_KEY=$(printf '%s\n' "$SSH_KEY" | awk 'NF == 2 { print $1, $2, "root@localhost"; next } { print }')

case "$(uname -m)" in
    x86_64) ARCH=amd64 ;;
    aarch64) ARCH=arm64 ;;
    *) echo 'Only x86_64 and aarch64 are supported' >&2; exit 1 ;;
esac

STAGE=/chise-rootfs
ARCHIVE=/chise-rootfs.tar.xz
[ ! -e "$STAGE" ] && [ ! -L "$STAGE" ] && [ ! -e "$ARCHIVE" ] || {
    echo "Remove the existing $STAGE or $ARCHIVE before retrying" >&2; exit 1;
}

if awk '$5 != "/" && $5 !~ /^\/(dev|proc|sys|run)(\/|$)/ { found=1; print "Extra mount:", $5 > "/dev/stderr" } END { exit !found }' /proc/self/mountinfo; then
    echo 'Extra mounts must be detached first; this script does not replace mounted volumes' >&2
    exit 1
fi

printf 'This will ERASE the current container filesystem. Type ERASE to continue: '
read -r ANSWER < /dev/tty
[ "$ANSWER" = ERASE ] || exit 1

if ! command -v xz >/dev/null 2>&1; then
    . /etc/os-release
    case "$ID" in
        alpine) apk add --no-cache xz ;;
        debian|ubuntu)
            apt-get update -q
            DEBIAN_FRONTEND=noninteractive apt-get install -y xz-utils ;;
        *) echo 'Install xz before running this script on this OS' >&2; exit 1 ;;
    esac
    command -v xz >/dev/null 2>&1 || { echo 'Failed to install xz' >&2; exit 1; }
fi

cleanup() {
    umount "$STAGE/proc" 2>/dev/null || true
    umount "$STAGE/dev" 2>/dev/null || true
    if awk -v stage="$STAGE" 'index($5, stage "/") == 1 || $5 == stage { found=1 } END { exit !found }' /proc/self/mountinfo; then
        echo "A mount remains under $STAGE; refusing to remove it" >&2
        return
    fi
    rm -rf -- "$STAGE" "$ARCHIVE"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

INDEX=$(curl -fsSL --retry 3 https://images.linuxcontainers.org/meta/1.0/index-system)
if [ "$DISTRO" = debian ]; then
    IMAGE=$(printf '%s\n' "$INDEX" | awk -F ';' -v arch="$ARCH" '$1=="debian" && $2=="trixie" && $3==arch && $4=="default" {print $6; exit}')
else
    IMAGE=$(printf '%s\n' "$INDEX" | awk -F ';' -v arch="$ARCH" '$1=="alpine" && $2 ~ /^3\.[0-9]+$/ && $3==arch && $4=="default" && substr($2,3)+0 > latest {latest=substr($2,3)+0; image=$6} END {print image}')
fi
case "$IMAGE" in /images/*/) ;; *) echo 'No matching system image found' >&2; exit 1 ;; esac

echo "Downloading $DISTRO ($ARCH): $IMAGE"
curl -fL --retry 3 "https://images.linuxcontainers.org${IMAGE}rootfs.tar.xz" -o "$ARCHIVE"
mkdir -m 700 "$STAGE"
tar -xJf "$ARCHIVE" -C "$STAGE"
rm "$ARCHIVE"
[ -x "$STAGE/bin/sh" ] || { echo 'Invalid rootfs image' >&2; exit 1; }

printf '%s\n' "$(hostname)" > "$STAGE/etc/hostname"
rm -f "$STAGE/etc/resolv.conf"
printf 'nameserver 9.9.9.9\nnameserver 2620:fe::fe\n' > "$STAGE/etc/resolv.conf"

mkdir -p "$STAGE/root/.ssh" "$STAGE/run/sshd" "$STAGE/etc/ssh"
printf '%s\n' "$SSH_KEY" > "$STAGE/root/.ssh/authorized_keys"
chmod 700 "$STAGE/root/.ssh"
chmod 600 "$STAGE/root/.ssh/authorized_keys"

mount --bind /dev "$STAGE/dev"
mount --bind /proc "$STAGE/proc"
if [ "$DISTRO" = debian ]; then
    chroot "$STAGE" /bin/sh -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update -q && apt-get install -y --no-install-recommends openssh-server ca-certificates iproute2 busybox-static nano'
    if [ ! -f "$STAGE/etc/systemd/network/eth0.network" ]; then
        mkdir -p "$STAGE/etc/systemd/network"
        printf '[Match]\nName=eth0\n\n[Network]\nDHCP=yes\nIPv6AcceptRA=yes\n' > "$STAGE/etc/systemd/network/20-chise.network"
    fi
    chroot "$STAGE" systemctl enable ssh systemd-networkd
    STATIC_BUSYBOX="$STAGE/bin/busybox"
else
    chroot "$STAGE" /bin/sh -c 'apk add --no-cache openssh ca-certificates iproute2 ifupdown-ng busybox-static nano && rc-update add sshd default && rc-update add networking default'
    if [ ! -s "$STAGE/etc/network/interfaces" ]; then
        printf 'auto eth0\niface eth0 inet dhcp\niface eth0 inet6 dhcp\n' > "$STAGE/etc/network/interfaces"
    fi
    printf 'RESOLV_CONF="no"\n' > "$STAGE/etc/udhcpc/udhcpc.conf"
    STATIC_BUSYBOX="$STAGE/bin/busybox.static"
fi

SSHD_CONFIG="$STAGE/etc/ssh/sshd_config"
if [ -f "$SSHD_CONFIG" ]; then
    cp "$SSHD_CONFIG" "$SSHD_CONFIG.orig"
fi
{
    printf 'PermitRootLogin prohibit-password\nPasswordAuthentication no\nPubkeyAuthentication yes\n'
    [ ! -f "$SSHD_CONFIG.orig" ] || cat "$SSHD_CONFIG.orig"
} > "$SSHD_CONFIG"
chroot "$STAGE" ssh-keygen -A
chroot "$STAGE" ssh-keygen -lf /root/.ssh/authorized_keys >/dev/null
chroot "$STAGE" sshd -t

[ -x "$STATIC_BUSYBOX" ] || { echo 'Static BusyBox was not installed' >&2; exit 1; }
cp "$STATIC_BUSYBOX" "$STAGE/busybox"
chroot "$STAGE" /busybox sh -c 'test -x /busybox && /busybox true'
umount "$STAGE/proc"
umount "$STAGE/dev"

echo 'Image ready. Replacing the old root filesystem...'
mkdir "$STAGE/oldroot"
mount --bind / "$STAGE/oldroot"
trap - EXIT HUP INT TERM
chroot "$STAGE" /busybox sh -ec '
    for entry in /oldroot/* /oldroot/.[!.]* /oldroot/..?*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        case "${entry##*/}" in dev|proc|sys|run|chise-rootfs) continue ;; esac
        /busybox rm -rf -- "$entry"
    done
    for entry in /* /.[!.]* /..?*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        case "${entry##*/}" in dev|proc|sys|run|oldroot|busybox) continue ;; esac
        /busybox mv -- "$entry" /oldroot/
    done
'

BUSYBOX="$STAGE/busybox"
"$BUSYBOX" umount "$STAGE/oldroot"
"$BUSYBOX" sync
"$BUSYBOX" rm -rf -- "$STAGE"
echo 'Done. Restart the container from the Incus host: incus restart <name>'
