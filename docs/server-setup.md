# Server Setup: Blank Linux Box → Running Immich

Target: any x86 Linux machine (mini-PC, spare laptop) with Ubuntu Server or
Debian, ≥8 GB RAM recommended (Immich ML wants ~4 GB), and a data disk with
room for 2 TB of photos.

## 1. Install Docker

    curl -fsSL https://get.docker.com | sudo sh
    sudo usermod -aG docker $USER   # log out and back in

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
    docker compose ps          # all services healthy/running after ~1 min

Open http://<server-ip>:2283 and create the FIRST account — this becomes the
admin. Create one account per family member (Administration → Users), or let
them register if you prefer.

## 6. Backup drive + cron

Plug in the external USB drive (≥4 TB), then:

    lsblk                                   # find it, e.g. /dev/sda1
    sudo mkdir -p /mnt/backup
    echo '/dev/sda1 /mnt/backup ext4 defaults,nofail 0 2' | sudo tee -a /etc/fstab
    sudo mount -a
    sudo touch /mnt/backup/.backup-drive    # marker checked by backup.sh
    sudo crontab -e
    # add:
    30 2 * * * /opt/family-photos/scripts/backup.sh

Run once manually and check it: `sudo /opt/family-photos/scripts/backup.sh`
then `cat /var/log/immich-backup.log`.

Now do the restore **verification drill** in `scripts/restore.md` — once, now,
while nothing is on fire.

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
