# Server Setup: Blank Linux Box → Running Immich

Target: any x86 Linux machine (mini-PC, spare laptop) with Ubuntu Server or
Debian, ≥8 GB RAM recommended (Immich ML wants ~4 GB), and a data disk with
room for 2 TB of photos.

## 1. Install Docker

    curl -fsSL https://get.docker.com | sudo sh

The convenience script is fine for a home server; for the apt-repository method see https://docs.docker.com/engine/install/.

    sudo usermod -aG docker $USER   # log out and back in

Log out and back in now (or run newgrp docker) — otherwise docker commands in step 5 fail with "permission denied".

## 2. Get this repo onto the server

    sudo mkdir -p /opt/family-photos && sudo chown $USER /opt/family-photos
    git clone <this-repo-url> /opt/family-photos
    cd /opt/family-photos

## 3. Prepare storage

    sudo mkdir -p /data/immich/library /data/immich/postgres

If /data is a separate disk, mount it via /etc/fstab first.

## 4. Configure

    cd immich
    cp example.env .env
    openssl rand -base64 30    # use output as DB_PASSWORD in .env
    nano .env                  # set DB_PASSWORD and TZ (e.g. America/Los_Angeles)

## 5. First start

    docker compose up -d
    docker compose ps          # all services healthy/running (first start takes several minutes: the ML container downloads its models)

Open http://<server-ip>:2283 and create the FIRST account — this becomes the
admin. Create one account per family member (Administration → Users).

## 6. Backup drive + cron

Plug in the external USB drive (≥4 TB), then:

    lsblk -f                                # find it (e.g. /dev/sda1) and note its filesystem
    # If the drive is new or NTFS/exFAT-formatted, format it for Linux first
    # (THIS ERASES THE DRIVE — double-check the device name):
    sudo mkfs.ext4 /dev/sda1
    # Mount by UUID, not device name — USB device names change between reboots:
    sudo blkid /dev/sda1                    # copy the UUID="..." value
    sudo mkdir -p /mnt/backup
    echo 'UUID=<paste-uuid-here> /mnt/backup ext4 defaults,nofail 0 2' | sudo tee -a /etc/fstab
    sudo mount -a
    sudo touch /mnt/backup/.backup-drive    # marker checked by backup.sh
    sudo crontab -e
    # add:
    30 2 * * * /opt/family-photos/scripts/backup.sh

Run once manually and check it: `sudo /opt/family-photos/scripts/backup.sh`
then `cat /var/log/immich-backup.log`.

Now do the restore **verification drill** in `scripts/restore.md` — once, now,
while nothing is on fire.

Backups fail silently if nobody looks: once a month, check that the last line
of `/var/log/immich-backup.log` says "backup completed OK". Off-site copies
(e.g. a Backblaze B2 sync of `/mnt/backup`) are a good later upgrade once this
is routine; note that the backup drive itself is unencrypted — anyone holding
it can read the photos, and since the drive also carries `immich.env`, they
can read the server's database password too.

## 7. Remote access

Follow `docs/tailscale-setup.md`.

## Troubleshooting: "the server seems down"

1. Is the box on and on the network? `ping <server-ip>` from your laptop.
2. Containers running? `cd /opt/family-photos/immich && docker compose ps`
3. Anything crash-looping? `docker compose logs --tail 50 immich-server`
4. Disk full? `df -h /data` — Immich stops accepting uploads on a full disk.
5. Tailscale up? `tailscale status` on the server.
6. Nuclear option (safe — photos are on the host disk):
   `docker compose down && docker compose up -d`
