#!/bin/bash
set -e

echo 'options thinkpad_acpi fan_control=1 experimental=1' | sudo tee /etc/modprobe.d/thinkpad_acpi.conf > /dev/null
sudo modprobe thinkpad_acpi
echo enable | sudo tee /proc/acpi/ibm/fan > /dev/null

OPTIONS=("auto" "disengaged" "full-speed" "0" "1" "2" "3" "4" "5" "6" "7")
NAMES=("Auto (BIOS controlled)" "Disengaged" "Full speed" "Off" "Level 1" "Level 2" "Level 3" "Level 4" "Level 5" "Level 6" "Level 7")

PS3='Select fan level: '
select opt in "${NAMES[@]}"; do
  case $opt in
    "Auto (BIOS controlled)") level="auto" ;;
    "Disengaged") level="disengaged" ;;
    "Full speed") level="full-speed" ;;
    "Off") level="0" ;;
    "Level 1") level="1" ;;
    "Level 2") level="2" ;;
    "Level 3") level="3" ;;
    "Level 4") level="4" ;;
    "Level 5") level="5" ;;
    "Level 6") level="6" ;;
    "Level 7") level="7" ;;
    *) echo "Invalid option" && exit 1 ;;
  esac
  echo level "$level" | sudo tee /proc/acpi/ibm/fan > /dev/null
  echo "Fan set to: $level"
  cat /proc/acpi/ibm/fan
  break
done