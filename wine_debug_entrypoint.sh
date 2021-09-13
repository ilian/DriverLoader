#!/usr/bin/env bash
# Attach gdb to the entrypoint of a Windows driver with wine
set -eo pipefail

sys_file="$1"
service_name="$2"

if [ $# -lt 2 ]; then
  echo "Driver not provided or does not exist" >&2
  echo "Usage: $0 DRIVER_PATH SERVICE_NAME" >&2
  echo "Example: $0 ./MyService.sys MyService" >&2
  exit 1
fi

if [ ! -f "$sys_file" ]; then
  echo "File not found: $sys_file" >&2
  exit 1
fi

if [ ! -f "main.exe" ]; then
  echo "Driver loader has not been built yet. Invoking 'make'."
  make
fi

get_header() {
  x86_64-w64-mingw32-objdump -p "$sys_file" 2>/dev/null | grep "$1" | awk '{print $2}'
}

ImageBase="0x$(get_header ImageBase)"
AddressOfEntryPoint="0x$(get_header AddressOfEntryPoint)"
EntryVAS=$(printf "%#x\n" $(($ImageBase + $AddressOfEntryPoint)))

echo "DriverEntry virtual address: $EntryVAS"

while read s; do
  sec_start=$(cut -d' ' -f1 <<< "$s")
  sec_size=$(cut -d' ' -f2 <<< "$s")
  sec_end=$(printf "%x\n" $((0x$sec_start + 0x$sec_size)))
  sec_file_offset=$(cut -d' ' -f3 <<< "$s")
  if (( 0x$sec_start <= $EntryVAS && $EntryVAS < 0x$sec_end)); then
    EntryFileOffset=$(($EntryVAS - 0x$sec_start + 0x$sec_file_offset))
    break
  fi
done < <(x86_64-w64-mingw32-objdump -h "$sys_file" 2>/dev/null | awk '/File off/ {header=1} header && $1 ~ /^[0-9]+$/ {print $4, $3, $6}')

printf "DriverEntry file offset: %#x\n" $EntryFileOffset

echo "Copying driver and placing breakpoint at $(printf "%#x" $EntryFileOffset)"
tempdir="$(mktemp -d)"
trap 'rm -rf "$tempdir"' EXIT
mod_sys_file="$tempdir/$(basename "$sys_file")"
cp -v "$sys_file" "$mod_sys_file"

orig_entrypoint_raw="$(dd if="$mod_sys_file" skip=$EntryFileOffset bs=1 count=1 status=none)"
orig_entrypoint_hex="$(printf "$orig_entrypoint_raw" | xxd -p)"

printf "\xcc" | dd of="$mod_sys_file" bs=1 seek=$EntryFileOffset count=1 conv=notrunc

echo "Starting wine"

if ! ps -A | grep wineserver; then
  wineserver -fp &
fi

# Cause services.exe to start
wine64 wineboot -h 2> /dev/null

echo "Attaching gdb to entrypoint of driver"

unix_to_win() {
  # Convert a UNIX path to a Windows path without depending on 'winepath -w'
  # to avoid starting other wine processes
  unixpath="$(realpath "$1")"
  # Assume default drive mapping of Z:\
  echo -n "Z:"
  sed 's/\//\\/g' <<< "$unixpath"
}

(sleep 1; exec wine64 main.exe "$(unix_to_win "$mod_sys_file")" "$service_name") &
gdb \
  -q \
  -ix gdbinit.py \
  -iex 'set detach-on-fork off' \
  -iex 'set schedule-multiple on' \
  -iex 'set pagination off' \
  -p "$(ps -A | grep services.exe | awk '{print $1}')" \
  -ex c \
  -ex 'inferior 1' \
  -ex c \
  -ex 'load-symbol-files' \
  -ex 'set scheduler-locking on' \
  -ex 'set {char}($rip-1) = 0x'"$orig_entrypoint_hex" \
  -ex 'set $rip = $rip - 1'

