#!/usr/bin/env bash
set -eu

declare -A boards=(
  ["klipper-skr-mini-v2.config"]="USB stm32f103xe_36FFD6054246303633571157-if00"
  ["klipper-sht36.config"]="USB stm32f072xb_450049001057425835303220-if00"
  ["klipper-v0display.config"]="USB stm32f042x6_23000C001843304754393320-if00"
)

usb_prefix="/dev/serial/by-id/usb-"
can_dev="can0"

klipper_path="$HOME/klipper"
katapult_path="$HOME/katapult"
flashtool="python3 ${katapult_path}/scripts/flashtool.py"
make_flags=("-j4")

function build_klipper() {
  pushd "$klipper_path"
  cp --force --no-target-directory "$1" .config
  make "${make_flags[@]}"
  popd
}

function flash_board() {
  echo UNIMPLEMENTED
}
# flash FLASH_DEVICE="$1"

function update_config() {
  python_code="
import kconfiglib
import sys
a = kconfiglib.Kconfig(filename=sys.argv[1])
a.load_config(filename=sys.argv[2],replace=False)
a.write_config(filename=sys.argv[2],save_old=True)
"
  pushd "$klipper_path"
  PYTHONPATH=lib/kconfiglib python3 -c "$python_code" src/Kconfig "$1"
  popd
}

configs_dir="$(realpath "$(dirname "$0")")"
sudo systemctl stop klipper

for config_name in "${!boards[@]}"; do
  conf="${boards[$config_name]}"
  conn_type="${conf%% *}" # first word in string
  conn_val="${conf##* }" # last word in string

  config_path="$configs_dir/$config_name"
  if ! [[ -e "$config_path" ]]; then
    echo "Config was not found! Skipping ${config_name}..."
    continue
  fi

  if [ "${conn_type,,}" = 'usb' ]; then
    serial_path="${usb_prefix}Klipper_${conn_val}"
    serial_katapult_path="${usb_prefix}katapult_${conn_val}"

    flash_args="-d ${serial_path}"
    if [ -e "$serial_katapult_path" ]; then
      echo "Already in bootloader"
    elif [ -e "$serial_path" ]; then
      echo "Entering bootloader..."
      err=0
      $flashtool $flash_args --request-bootloader || err=$?
      if [ $err -ne 0 ]; then
        echo "Error. Skipping ${config_name}..."
        continue
      fi
    else
      echo "Serial connection path was not found! Skipping ${config_name}..."
      continue
    fi
    flash_args="-d ${serial_katapult_path}"
  elif [ "${conn_type,,}" = 'can' ]; then
    flash_args="-i ${can_dev} -u ${conn_val}"
    err=0
    $flashtool $flash_args --request-bootloader || err=$?
    sleep 1
    $flashtool $flash_args --status || err=$?
    if [ $err -ne 0 ]; then
      echo "CAN bus error. Skipping ${config_name}..."
      continue
    fi
  else
    echo "Invalid connection type \"${conn_type,,}\" for ${config_name}! Skipping ${config_name}..."
    continue
  fi

  echo "Update board config: $config_path"
  update_config "$config_path"
  echo "Build Klipper"
  build_klipper "$config_path"
  echo "Flash Klipper"
  $flashtool $flash_args -f "$klipper_path/out/klipper.bin" \
  && echo "Updated $serial_path with config $config_path!"
done
sudo systemctl start klipper
