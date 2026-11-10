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

for command in tar mount umount chroot awk cp hostname; do
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

# Proxmox rewrites the network config and DNS from the CT config at every start.
case "$(uname -r)" in *-pve) PROXMOX=1 ;; *) PROXMOX=0 ;; esac
OLD_ID=
[ ! -r /etc/os-release ] || OLD_ID=$(. /etc/os-release; printf '%s' "${ID:-}")

# Prints field $2 (via or dev) of the IPv$1 default route. With $3 set, routes learned
# from DHCP or router adverts are skipped, since the new system learns those itself.
default_route() {
    ip -"$1" route show 2>/dev/null | awk -v want="$2" -v static_only="${3:-}" '
        $1 == "default" && !(static_only && (/ proto (dhcp|ra)( |$)/ || / expires /)) {
            for (i = 2; i < NF; i++) if ($i == want) { print $(i + 1); exit }
        }'
}

# Permanent global addresses on interface $1; ones with a lifetime came from DHCP or SLAAC.
static_addrs() {
    ip -o addr show dev "$1" 2>/dev/null | awk '
        ($3 == "inet" || $3 == "inet6") && / scope global / && !/ dynamic / && / valid_lft forever / { print $4 }'
}

# True if the current system sets its addresses itself rather than by DHCP.
has_static_config() {
    grep -qsE '^[[:space:]]*iface[[:space:]].*[[:space:]]static([[:space:]]|$)' \
        /etc/network/interfaces /etc/network/interfaces.d/* ||
    grep -qsE '^[[:space:]]*(Address|Gateway)[[:space:]]*=' /etc/systemd/network/*.network ||
    grep -qsE '^[[:space:]]*method[[:space:]]*=[[:space:]]*manual' /etc/NetworkManager/system-connections/*
}

has_static_ipv4() {
    for addr in $NET_ADDRS; do case "$addr" in *:*) ;; *) return 0 ;; esac; done
    return 1
}

write_networkd_static() {
    {
        printf '[Match]\nName=%s\n\n[Network]\n' "$NET_IF"
        has_static_ipv4 || echo 'DHCP=ipv4'
        for addr in $NET_ADDRS; do printf 'Address=%s\n' "$addr"; done
        for gw in $NET_GW4 $NET_GW6; do printf '\n[Route]\nGateway=%s\nGatewayOnLink=yes\n' "$gw"; done
    } > "$1"
}

# ifupdown-ng syntax: one stanza, address family taken from each address.
write_ifupdown_static() {
    {
        printf 'auto lo\niface lo inet loopback\n\nauto %s\niface %s\n' "$NET_IF" "$NET_IF"
        has_static_ipv4 || echo '    use dhcp'
        for addr in $NET_ADDRS; do printf '    address %s\n' "$addr"; done
        for gw in $NET_GW4 $NET_GW6; do printf '    gateway %s\n' "$gw"; done
    } > "$1"
}

STAGE=/chise-rootfs
ARCHIVE=/chise-rootfs.tar.xz
[ ! -e "$STAGE" ] && [ ! -L "$STAGE" ] && [ ! -e "$ARCHIVE" ] || {
    echo "Remove the existing $STAGE or $ARCHIVE before retrying" >&2; exit 1;
}

if awk '$5 != "/" && $5 !~ /^\/(dev|proc|sys|run)(\/|$)/ { found=1; print "Extra mount:", $5 > "/dev/stderr" } END { exit !found }' /proc/self/mountinfo; then
    echo 'Extra mounts must be detached first; this script does not replace mounted volumes' >&2
    exit 1
fi

printf 'DNS: 1) Quad9  2) Google [1/2]: '
read -r DNS_MODE < /dev/tty
if [ "$DNS_MODE" = 2 ]; then
    DNS4=8.8.8.8
    DNS6=2001:4860:4860::8888
else
    DNS4=9.9.9.9
    DNS6=2620:fe::fe
fi

# Proxmox restores the CT's addresses itself; elsewhere offer to keep the current ones,
# since the new image only knows DHCP.
NET_STATIC=0 NET_IF=eth0 NET_ADDRS= NET_GW4= NET_GW6=
if [ "$PROXMOX" = 0 ] && command -v ip >/dev/null 2>&1; then
    NET_IF=$(default_route 4 dev)
    [ -n "$NET_IF" ] || NET_IF=$(default_route 6 dev)
    NET_IF=${NET_IF:-eth0}
    NET_ADDRS=$(static_addrs "$NET_IF")
    NET_GW4=$(default_route 4 via static)
    NET_GW6=$(default_route 6 via static)
    if [ -n "$NET_ADDRS" ]; then
        if has_static_config; then NET_DEFAULT=2; else NET_DEFAULT=1; fi
        echo "Addresses on $NET_IF:" $NET_ADDRS
        [ -z "$NET_GW4$NET_GW6" ] || echo 'Gateways:' $NET_GW4 $NET_GW6
        printf 'Network: 1) DHCP  2) Static, keep these addresses [%s]: ' "$NET_DEFAULT"
        read -r NET_MODE < /dev/tty
        if [ "${NET_MODE:-$NET_DEFAULT}" = 2 ]; then NET_STATIC=1; fi
    fi
fi

printf 'This will ERASE the current container filesystem. Type ERASE to continue: '
read -r ANSWER < /dev/tty
[ "$ANSWER" = ERASE ] || exit 1

APK_PKGS= APT_PKGS=
command -v curl >/dev/null 2>&1 || { APK_PKGS=curl; APT_PKGS=curl; }
command -v xz >/dev/null 2>&1 || { APK_PKGS="$APK_PKGS xz"; APT_PKGS="$APT_PKGS xz-utils"; }
if [ -n "$APK_PKGS" ]; then
    . /etc/os-release
    case "$ID" in
        alpine) apk add --no-cache $APK_PKGS ;;
        debian|ubuntu)
            apt-get update -q
            DEBIAN_FRONTEND=noninteractive apt-get install -y $APT_PKGS ;;
        *) echo 'Install curl and xz before running this script on this OS' >&2; exit 1 ;;
    esac
    for command in curl xz; do
        command -v "$command" >/dev/null 2>&1 || { echo "Failed to install $command" >&2; exit 1; }
    done
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
printf 'nameserver %s\nnameserver %s\n' "$DNS4" "$DNS6" > "$STAGE/etc/resolv.conf"

if [ "$PROXMOX" = 1 ]; then
    # Keep the DNS chosen above instead of the one Proxmox writes at every start.
    : > "$STAGE/etc/.pve-ignore.resolv.conf"
    # Keep the CT's static addresses until Proxmox rewrites this file at the next start.
    if [ -s /etc/network/interfaces ]; then
        mkdir -p "$STAGE/etc/network"
        cp /etc/network/interfaces "$STAGE/etc/network/interfaces"
    fi
fi

# Per-container TCP settings; BBR only if the host lets containers choose it.
mkdir -p "$STAGE/etc/sysctl.d"
{
    grep -qw bbr /proc/sys/net/ipv4/tcp_allowed_congestion_control 2>/dev/null &&
        echo 'net.ipv4.tcp_congestion_control=bbr'
    printf 'net.ipv4.tcp_fastopen=3\nnet.ipv4.tcp_slow_start_after_idle=0\nnet.ipv4.tcp_mtu_probing=1\n'
} > "$STAGE/etc/sysctl.d/99-chise.conf"

mkdir -p "$STAGE/root/.ssh" "$STAGE/run/sshd" "$STAGE/etc/ssh"
printf '%s\n' "$SSH_KEY" > "$STAGE/root/.ssh/authorized_keys"
chmod 700 "$STAGE/root/.ssh"
chmod 600 "$STAGE/root/.ssh/authorized_keys"

mount --bind /dev "$STAGE/dev"
mount --bind /proc "$STAGE/proc"
if [ "$DISTRO" = debian ]; then
    # Proxmox writes the CT's addresses only as ifupdown config. ifupdown needs dhclient
    # for DHCPv6; dhcpcd only covers IPv4.
    [ "$PROXMOX" = 1 ] && NET_PKG='ifupdown isc-dhcp-client' || NET_PKG=
    chroot "$STAGE" /bin/sh -c "export DEBIAN_FRONTEND=noninteractive; apt-get update -q && apt-get install -y --no-install-recommends openssh-server ca-certificates iproute2 busybox-static nano $NET_PKG"
    if [ "$PROXMOX" = 1 ]; then
        # The image's DHCP-only eth0.network would ignore the CT's static IPs. Mask rather
        # than disable, or the first-boot presets turn networkd back on.
        rm -f "$STAGE/etc/systemd/network/eth0.network"
        chroot "$STAGE" systemctl mask systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service
        chroot "$STAGE" systemctl enable ssh networking
    else
        mkdir -p "$STAGE/etc/systemd/network"
        if [ "$NET_STATIC" = 1 ]; then
            # Replace the image's DHCP-only eth0.network.
            rm -f "$STAGE/etc/systemd/network/eth0.network"
            write_networkd_static "$STAGE/etc/systemd/network/20-chise.network"
        elif [ ! -f "$STAGE/etc/systemd/network/eth0.network" ]; then
            printf '[Match]\nName=eth0\n\n[Network]\nDHCP=yes\nIPv6AcceptRA=yes\n' > "$STAGE/etc/systemd/network/20-chise.network"
        fi
        chroot "$STAGE" systemctl enable ssh systemd-networkd
    fi
    # resolv.conf is a static file now, so the image's systemd-resolved has nothing to do.
    chroot "$STAGE" systemctl disable systemd-resolved 2>/dev/null || true
    STATIC_BUSYBOX="$STAGE/bin/busybox"
else
    chroot "$STAGE" /bin/sh -c 'apk add --no-cache openssh ca-certificates iproute2 ifupdown-ng busybox-static nano && rc-update add sshd default && rc-update add networking default && rc-update add sysctl boot'
    if [ "$NET_STATIC" = 1 ]; then
        write_ifupdown_static "$STAGE/etc/network/interfaces"
    elif [ ! -s "$STAGE/etc/network/interfaces" ]; then
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
if [ "$PROXMOX" = 1 ]; then
    [ "$OLD_ID" = "$DISTRO" ] ||
        echo "Proxmox still has this CT's old OS type; on the host run: pct set <id> --ostype $DISTRO"
    echo 'Done. Restart the container from the Proxmox host (pct reboot <id>) or your provider panel'
else
    echo 'Done. Restart the container from the Incus host: incus restart <name>'
fi
