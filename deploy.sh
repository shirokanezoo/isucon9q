#!/bin/bash -ex
selfsum="$(openssl dgst -sha256 "$0")"
#export PATH=/home/isucon/local/ruby/bin:$PATH
#
cd ~/git/
git pull --rebase
if [ "_${selfsum}" != "_$(openssl dgst -sha256 "$0")" ]; then
  exec $0
fi

sudo cp ~/git/systemd/* /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl restart isucari.ruby.service

sudo cp ~/git/nginx.conf /etc/nginx/nginx.conf

sudo nginx -t
sudo nginx -s reload || :

sudo bash -c 'cp /var/log/nginx/access.log /var/log/nginx/access.log.$(date +%s) && echo > /var/log/nginx/access.log; echo > /tmp/isu-query.log; echo > /tmp/isu-rack.log; test -d /tmp/stackprof && rm -f /tmp/stackprof/*; echo > /var/lib/mysql/mysql-slow.log'
