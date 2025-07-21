#!/bin/sh
set -e

if [ ! -f "/etc/acme.sh/ssl/${DOMAIN}/fullchain.pem" ]; then
    acme.sh --issue -d ${DOMAIN} --dns dns_cf
    acme.sh --install-cert -d ${DOMAIN} --key-file /etc/acme.sh/ssl/${DOMAIN}/key.pem \
    --fullchain-file /etc/acme.sh/ssl/${DOMAIN}/fullchain.pem
    acme.sh --deploy -d ${DOMAIN} --deploy-hook docker
fi