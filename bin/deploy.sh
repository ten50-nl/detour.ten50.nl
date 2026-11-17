#!/bin/bash
# Static site on the Hetzner server (no CMS core, no database). Run from the Mac.
#   --setup     create (or repair) the site accounts and dirs, install server/vhost.conf (and server/pool.conf when
#               the site has PHP), reload Apache/PHP-FPM. Idempotent. Do not use add-site.sh for this site: it would
#               create a database and overwrite the vhost.
#   (default)   clean export of HEAD public/, rsync to releases/<id>, atomic switch of current, health check through
#               the server itself (switches back on failure), keep 3 releases.
#   --rollback  switch current back to the previous release.
# The vhost picks the Let's Encrypt certificate by itself once /etc/letsencrypt/live/<domain> exists (reload Apache).
# Usage: bin/deploy.sh [--setup|--rollback]
set -euo pipefail
cd "$(dirname "$0")/.."
d=$(basename "$PWD")
T=${HETZNER_HOST:-ten50-web}
user=$(echo "${d%.*}" | tr -c 'a-z0-9\n' '_' | cut -c1-28)
deploy=$(echo "deploy_$user" | cut -c1-32)
root=/var/www/$d
php=0; [ -f server/pool.conf ] && php=1
hz() { ssh -o BatchMode=yes -o LogLevel=ERROR -o ServerAliveInterval=15 "$T" "$@"; }
health() { hz "curl -sk --max-time 20 --resolve $d:443:127.0.0.1 -o /dev/null -w '%{http_code}' https://$d/"; }

if [ "${1:-}" = --setup ]; then
  pv=$(hz 'cat /etc/ten50/php-version')
  hz "mkdir -p /root/ten50-static/$d"
  scp -q -o BatchMode=yes -o LogLevel=ERROR server/*.conf "$T:/root/ten50-static/$d/"
  hz "set -e
    id $user >/dev/null 2>&1 || useradd --system --create-home --home-dir $root --shell /usr/sbin/nologin $user
    id $deploy >/dev/null 2>&1 || useradd --system --user-group --no-create-home --home-dir $root --shell /usr/sbin/nologin $deploy
    usermod -a -G $user $deploy
    install -d -o $deploy -g $user -m 750 $root
    setfacl -m u:www-data:x $root
    install -d -o $deploy -g $user -m 755 $root/releases $root/shared
    install -d -o $user -g $user -m 750 $root/logs
    install -d -o root -g adm -m 750 /var/log/apache2/sites /var/log/apache2/sites/$d
    touch /var/log/apache2/sites/$d/error.log /var/log/apache2/sites/$d/access.log
    chown root:adm /var/log/apache2/sites/$d/*.log; chmod 640 /var/log/apache2/sites/$d/*.log
    if [ $php = 1 ]; then
      install -d -o $user -g $user -m 700 $root/tmp
      touch $root/logs/php-error.log; chown $user:$user $root/logs/php-error.log; chmod 640 $root/logs/php-error.log
      [ -f $root/shared/config.php ] || install -o root -g $user -m 640 /dev/null $root/shared/config.php
      chown root:$user $root/shared/config.php; chmod 640 $root/shared/config.php
      install -o root -g root -m 644 /root/ten50-static/$d/pool.conf /etc/php/$pv/fpm/pool.d/$user.conf
      printf '%s\n' '$root/logs/php-error.log {' '    su $user $user' '    weekly' '    rotate 8' '    compress' '    delaycompress' '    missingok' '    notifempty' '    copytruncate' '}' > /etc/logrotate.d/$user
      php-fpm$pv -t 2>/dev/null
      systemctl reload php$pv-fpm
    fi
    install -o root -g root -m 644 /root/ten50-static/$d/vhost.conf /etc/apache2/sites-available/$d.conf
    a2ensite -q $d
    apachectl configtest 2>/dev/null
    systemctl reload apache2
    rm -rf /root/ten50-static/$d
    echo \"setup: $d ready (accounts $user/$deploy, root $root, php $php)\""
  exit
fi

hz "[ -d $root/releases ]" || { echo "$d is not set up on $T, run bin/deploy.sh --setup first" >&2; exit 1; }

if [ "${1:-}" = --rollback ]; then
  prev=$(hz "ls -1 $root/releases | sort | tail -2 | head -1")
  cur=$(hz "basename \$(readlink $root/current)")
  [ -n "$prev" ] && [ "$prev" != "$cur" ] || { echo "no previous release" >&2; exit 1; }
  hz "sudo -u $deploy ln -sfn releases/$prev $root/current.new && sudo -u $deploy mv -T $root/current.new $root/current && rm -rf $root/releases/$cur"
  echo "rolled back to $prev (health $(health))"
  exit
fi

[ -z "$(git status --porcelain)" ] || { echo "uncommitted changes" >&2; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
git archive HEAD public | tar -x -C "$tmp"
phpfiles=$(cd "$tmp/public" && find . -type f -iname '*.php*' | grep -v '^\./api/' || true)
[ $php = 1 ] || phpfiles=$(cd "$tmp/public" && find . -type f -iname '*.php*' || true)
[ -z "$phpfiles" ] || { echo "PHP files where this vhost has no PHP handler (they would be served as source): $phpfiles" >&2; exit 1; }
P85=/opt/homebrew/opt/php@8.5/bin/php
if [ $php = 1 ] && [ -x $P85 ]; then
  lint=$(find "$tmp/public" -name '*.php' -print0 | xargs -0 -n1 $P85 -n -d error_reporting=E_ALL -d display_errors=stderr -l 2>&1 | grep -v '^No syntax errors' || true)
  [ -z "$lint" ] || { echo "$lint" | sed "s#$tmp/##" >&2; echo "lint: PHP 8.5 errors or deprecations, deploy stopped" >&2; exit 1; }
fi
if [ $php = 1 ]; then
  ln -s ../../../shared/config.php "$tmp/public/api/config.php"
fi
id=$(date -u +%Y%m%d%H%M%S)-$(git rev-parse --short HEAD)
rsync -rlt --delete -e "ssh -o BatchMode=yes -o LogLevel=ERROR" "$tmp/public/" "$T:$root/releases/$id/"
hz "set -e; chown -R -h $deploy:$user $root/releases/$id; chmod -R u=rwX,go=rX $root/releases/$id; prev=\$(readlink $root/current || true)
  sudo -u $deploy ln -sfn releases/$id $root/current.new && sudo -u $deploy mv -T $root/current.new $root/current
  code=\$(curl -sk --max-time 20 --resolve $d:443:127.0.0.1 -o /dev/null -w '%{http_code}' https://$d/)
  if [ \"\$code\" != 200 ]; then
    if [ -n \"\$prev\" ]; then sudo -u $deploy ln -sfn \$prev $root/current.new && sudo -u $deploy mv -T $root/current.new $root/current; fi
    echo \"health check \$code, switched back to \${prev:-nothing}\" >&2; exit 1
  fi
  cd $root/releases && ls -1 | sort | head -n -3 | xargs -r rm -rf
  echo \"release $id live on the server (health \$code), releases: \$(ls -1 | wc -l)\""
