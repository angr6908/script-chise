# chise.sh

Debian 13 (Trixie) minimal install script (~165 MB after install).

## Key Features

- Root filesystem selectable: Btrfs (zstd compression, async discard) or ext4 (weekly fstrim)  
- IPv4/IPv6 support via systemd-networkd (selectable: DHCP or static)  
- Works on UEFI (GPT) and BIOS (MBR) systems  
- Enables BBR + FQ, zRAM, and NTP time sync by default  
- SSH key–only access  

## Usage

### On Alpine / Debian Rescue System / Live OS

```bash
curl -LO cdn.jsdelivr.net/gh/angr6908/script-chise/chise.sh && sh chise.sh --ssh-key "your-key"
```

### On Any System

#### Step 1: Reboot into Alpine Live OS

```bash
curl -LO cdn.jsdelivr.net/gh/bin456789/reinstall/reinstall.sh && bash reinstall.sh alpine --hold 1 --ssh-key "your-key"
```

#### Step 2: Install chise.sh
```bash
curl -LO cdn.jsdelivr.net/gh/angr6908/script-chise/chise.sh && sh chise.sh --ssh-key "your-key"
```

## Docker Installation Script (Btrfs Driver) (+ 127MB)
```bash
mkdir -p /etc/docker && echo '{"storage-driver": "btrfs"}' > /etc/docker/daemon.json && install -m 0755 -d /etc/apt/keyrings && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && chmod a+r /etc/apt/keyrings/docker.asc && echo -e "Types: deb\nURIs: https://download.docker.com/linux/debian\nSuites: $(. /etc/os-release && echo "$VERSION_CODENAME")\nComponents: stable\nSigned-By: /etc/apt/keyrings/docker.asc" | tee /etc/apt/sources.list.d/docker.sources && apt update && apt install --no-install-recommends docker-ce docker-ce-cli containerd.io docker-compose-plugin -y
```
