# Checks a napkin store path before the panel reads or writes it.
#
#   bash store-guard.sh <absolute file path> [pinned folder]
#
# Run by Store.qml as `/usr/bin/bash store-guard.sh ...`, never executed
# directly, and every external command below is called by absolute path, so
# nothing here is looked up on $PATH.
#
# On success it prints the folder's fully resolved path and exits 0. Store.qml
# hands FileView that resolved path rather than the configured one, and passes
# it back as `pinned` on every later check: if the configured path ever resolves
# somewhere else (a folder along the way swapped for a symlink), the check fails
# instead of quietly following it. The exit codes are mapped to messages in
# Store.qml.
#
# This narrows the gap between checking the path and FileView using it; it does
# not close it. A process running as the same user can still swap something in
# the milliseconds between this exiting and the write that follows. Closing that
# needs file-descriptor access, which QML does not have.

set -u
path=$1
pinned=${2-}

# Absolute, naming a file. Store.qml refuses anything else before calling this;
# these are the backstop.
case $path in
  */) exit 10 ;;
  /*) ;;
  *) exit 10 ;;
esac
name=${path##*/}
case $name in
  ''|.|..) exit 10 ;;
esac
dir=${path%/*}
[ -n "$dir" ] || dir=/

/usr/bin/mkdir -p -m 700 -- "$dir" 2>/dev/null || exit 2

# Everything below is checked against the resolved, symlink-free folder. A
# folder the user symlinked on purpose (a synced notes dir, say) still works;
# it is just pinned to where it pointed the first time.
real=$(/usr/bin/realpath -e -- "$dir" 2>/dev/null) || exit 14
[ -z "$pinned" ] || [ "$real" = "$pinned" ] || exit 11

# Every folder from / down, in one stat call.
comps=(/)
rest=${real#/}
cur=""
while [ -n "$rest" ]; do
  part=${rest%%/*}
  cur=$cur/$part
  comps+=("$cur")
  [ "$rest" = "$part" ] && break
  rest=${rest#*/}
done

info=$(/usr/bin/stat -c '%u %a %F' -- "${comps[@]}" 2>/dev/null) || exit 14
last=$(( ${#comps[@]} - 1 ))
i=0
while read -r owner mode type; do
  # realpath resolved every link, so anything but a folder means the path
  # changed while this was running.
  [ "$type" = directory ] || exit 4
  if [ "$i" -eq "$last" ]; then
    # The notes folder itself: ours, and nobody else can write in it.
    [ "$owner" -eq "$EUID" ] || exit 5
    (( 8#$mode & 8#022 )) && exit 6
  else
    # A folder above it: root's or ours. Anyone else who can write in one could
    # swap out everything beneath it, except in a root-owned sticky folder like
    # /tmp, where the sticky bit already stops them renaming our entries.
    [ "$owner" -eq 0 ] || [ "$owner" -eq "$EUID" ] || exit 13
    if (( 8#$mode & 8#022 )); then
      { [ "$owner" -eq 0 ] && (( 8#$mode & 8#1000 )); } || exit 6
    fi
  fi
  i=$(( i + 1 ))
done <<< "$info"

if [ "$real" = / ]; then file=/$name; else file=$real/$name; fi
[ -L "$file" ] && exit 7
if [ -e "$file" ]; then
  finfo=$(/usr/bin/stat -c '%u %a %F' -- "$file" 2>/dev/null) || exit 14
  read -r owner mode type <<< "$finfo"
  case $type in
    "regular file"|"regular empty file") ;;
    *) exit 8 ;;
  esac
  [ "$owner" -eq "$EUID" ] || exit 9
  (( 8#$mode & 8#022 )) && exit 12
fi

printf '%s' "$real"
exit 0
