#!/bin/bash
set -euo pipefail

program=/usr/bin/omarchy-provision-owner
test "$(tail -n 1 "$program")" = main
source <(sed '$d' "$program")

username=@GUEST_USER@
password=@GUEST_PASSWORD@
full_name="Telar Development"
email_address="development@example.invalid"
hostname=telar-omarchy
keyboard_label="English (US)"
timezone=$(tzupdate -p 2>/dev/null) || timezone=UTC

platform_ready
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
rm -f "$FINALIZE_WARNING_FLAG"
echo account > "$STATE_FILE"
run_provisioning >> "$LOG_FILE" 2>&1

install -d -m 755 /etc/sudoers.d
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$username" > /etc/sudoers.d/90-telar-development
chmod 440 /etc/sudoers.d/90-telar-development
visudo -cf /etc/sudoers.d/90-telar-development
rm -f /etc/systemd/system/omarchy-provision-owner.service.d/50-telar-development.conf
rm -f /usr/local/lib/telar-vm/owner-setup
