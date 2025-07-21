#!/bin/sh
set -e

if [ ! -f "/etc/v2ray/config.json" ]; then
    export VMESS_UUID=${VMESS_UUID:-$(v2ray uuid)}
    envsubst < /etc/v2ray/template.json > /etc/v2ray/config.json
fi

exec v2ray run -config=/etc/v2ray/config.json