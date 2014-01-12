#!/bin/bash
# write image to sd card via builtin mac sd slot

BLK_SZ=1048576

# sanity check
uname=`uname -s | fgrep Darwin`
if [ -z "${uname}" ]
then
    echo "sorry, this script only runs on a mac"
    exit 1
fi
if [ -z "${1}" ]
then
    echo "usage: ${0} /path/to/file.img"
    exit 1
fi
if [ ! -s "${1}" ]
then
    echo "${1} empty or missing"
    exit 1
fi
image_file="${1}"
target_disk=""

# builtin sd slot found?
for disk in `diskutil list | grep '^\/' | cut -f3 -d\/`
do
    sd_reader=`diskutil info -plist ${disk} | plutil -extract MediaName binary1 -o - - | plutil -p - | grep 'APPLE SD.* Card Reader Media'`
    if [ -n "${sd_reader}" ]
    then
        target_disk=${disk}
        break
    fi
done
if [ -z "${target_disk}" ]
then
    echo "no sd card found"
    exit 1
fi

# proceed?
echo
diskutil list ${target_disk}
prompt="${image_file} => ${target_disk}? [y/n]: " 
echo
while :
do
    read -p "${prompt}" yesno
    case $yesno in
        y) break    ;;
        n) exit 1   ;;
        *) yesno="" ;;
    esac
done
echo

# dd image to sd card
sudo diskutil unmountDisk ${target_disk} || exit 1
echo
epoch=`date +%s`
out_f="/tmp/.dd.out.$$.${epoch}"
sudo -b dd if="${image_file}" of="/dev/${target_disk}" bs=${BLK_SZ} 2> ${out_f}

# wait for dd to finish
pid=`pgrep -n -u 0 -x dd`
while :
do
    sudo kill -29 ${pid} 2> /dev/null || break
    progress=`tail -1 ${out_f} | awk '{print $1,$2,$3,$7,$8}'`
    echo -ne "${progress}\r"
    sleep 10
done
wait

# clean up
tail -1 ${out_f}
/bin/rm -f ${out_f}
echo
diskutil eject ${target_disk}

# eof
