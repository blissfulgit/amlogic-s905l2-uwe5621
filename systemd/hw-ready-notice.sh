#!/bin/sh
# 登录时展示硬件闸门状态（仅在交互式 shell 生效）
# 安装到 /etc/profile.d/hw-ready-notice.sh

case $- in *i*) ;; *) exit 0 ;; esac
[ -r /run/hardware-status ] || exit 0

if [ -f /run/hardware-ready ]; then
    _state=$(awk '$1=="STATE"{s=$2} END{print s}' /run/hardware-status)
    _el=$(awk '$1=="STATE"{s=$3} END{print s}' /run/hardware-status)
    _detail=$(awk '$1!="STATE"{printf "%s=%s ", $2, $3}' /run/hardware-status | sed 's/ $//')
    printf ' hardware: %s (%s)  %s\n' "${_state:-unknown}" "${_el:-?}" "$_detail"
else
    printf ' hardware: initializing…  (WiFi/Bluetooth 尚未就绪，可查 /run/hardware-status)\n'
fi
