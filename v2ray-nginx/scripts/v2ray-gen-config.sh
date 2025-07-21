#!/bin/sh
set -e
export VMESS_UUID=${VMESS_UUID:-$(v2ray uuid)}
envsubst < /etc/ssl/template.json > /etc/v2ray/config.json

exec v2ray run -config=/etc/v2ray/config.json