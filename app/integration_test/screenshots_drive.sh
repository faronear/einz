#!/bin/bash
# App Store 截图宿主机驱动（配合 app/integration_test/screenshots_test.dart 的文件握手）：
# 等 ready_i 信号 → simctl 截图 → 撤信号。用法：bash screenshots_drive.sh [sim_id]
set -e
SIM="${1:-85FE339B-8A1E-4D2B-BD8A-74BEE7187668}"
DIR=/tmp/einz_shots
mkdir -p "$DIR"
names=(01_wizard_entry 02_chat_main 03_long_press_menu 04_burn_settings 05_attach_panel 06_pin_setup)
for i in 1 2 3 4 5 6; do
  for _ in $(seq 1 600); do
    [ -f "$DIR/ready_$i" ] && break
    sleep 1
  done
  if [ ! -f "$DIR/ready_$i" ]; then echo "TIMEOUT waiting ready_$i" >&2; exit 1; fi
  xcrun simctl io "$SIM" screenshot "$DIR/${names[$((i-1))]}.png"
  rm -f "$DIR/ready_$i"
  echo "SHOT ${names[$((i-1))]}"
done
echo DRIVE-DONE
