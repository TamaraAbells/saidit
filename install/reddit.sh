#!/bin/bash
###############################################################################
# reddit dev environment installer
# --------------------------------
# This script installs a reddit stack suitable for development. DO NOT run this
# on a system that you use for other purposes as it might delete important
# files, truncate your databases, and otherwise do mean things to you.
#
# By default, this script will install the reddit code in the current user's
# home directory and all of its dependencies (including libraries and database
# servers) at the system level. The installed reddit will expect to be visited
# on the domain "reddit.local" unless specified otherwise.  Configuring name
# resolution for the domain is expected to be done outside the installed
# environment (e.g. in your host machine's /etc/hosts file) and is not
# something this script handles.
#
# Several configuration options (listed in the "Configuration" section below)
# are overridable with environment variables. e.g.
#
#    sudo REDDIT_DOMAIN=example.com ./install/reddit.sh
#
###############################################################################

# load configuration
RUNDIR=$(dirname $0)
source $RUNDIR/install.cfg


###############################################################################
# Sanity Checks
###############################################################################
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Must be run with root privileges."
    exit 1
fi

if [[ -z "$REDDIT_USER" ]]; then
    # in a production install, you'd want the code to be owned by root and run
    # by a less privileged user. this script is intended to build a development
    # install, so we expect the owner to run the app and not be root.
    cat <<END
ERROR: You have not specified a user. This usually means you're running this
script directly as root. It is not recommended to run reddit as the root user.

Please create a user to run reddit and set the REDDIT_USER variable
appropriately.
END
    exit 1
fi

if [[ "amd64" != $(dpkg --print-architecture) ]]; then
    cat <<END
ERROR: This host is running the $(dpkg --print-architecture) architecture!

Because of the pre-built dependencies in our PPA, and some extra picky things
like ID generation in liveupdate, installing reddit is only supported on amd64
architectures.
END
    exit 1
fi

# seriously! these checks are here for a reason. the packages ren't built for
# anything but Ubuntu 18.04 right now, so if you try and use this install
# script on another release you're gonna have a bad time.
source /etc/lsb-release
if [ "$DISTRIB_ID" != "Ubuntu" -o "$DISTRIB_RELEASE" != "18.04" ]; then
    echo "ERROR: Only Ubuntu 18.04 is supported."
    exit 1
fi

if [[ "2000000" -gt $(awk '/MemTotal/{print $2}' /proc/meminfo) ]]; then
    LOW_MEM_PROMPT="reddit requires at least 2GB of memory to work properly, continue anyway? [y/n] "
    read -er -n1 -p "$LOW_MEM_PROMPT" response
    if [[ "$response" != "y" ]]; then
      echo "Quitting."
      exit 1
    fi
fi

###############################################################################
# Install prerequisites
###############################################################################

# install primary packages
$RUNDIR/install_apt.sh

# install pip packages
$RUNDIR/install_pip.sh

# install cassandra from datastax
$RUNDIR/install_cassandra.sh

# install zookeeper
$RUNDIR/install_zookeeper.sh

# install services (rabbitmq, postgres, memcached, etc.)
$RUNDIR/install_services.sh

###############################################################################
# Install the reddit source repositories
###############################################################################
if [ ! -d $REDDIT_SRC ]; then
    mkdir -p $REDDIT_SRC
    chown $REDDIT_USER $REDDIT_SRC
fi

# TODO PORT - check all dl'ed repos for 'upstart' folders, port to systemd, then remove this function
function copy_upstart {
    if [ -d ${1}/upstart ]; then
        cp ${1}/upstart/* /etc/init/
    fi
}

function copy_service {
    if [ -d ${1}/services ]; then
        cp ${1}/services/* /etc/systemd/system
    fi
}

function clone_reddit_repo {
    local destination=$REDDIT_SRC/${1}
    local repository_url=https://github.com/${2}.git

    if [ ! -d $destination ]; then
        sudo -u $REDDIT_USER -H git clone $repository_url $destination
    fi

    copy_upstart $destination
}

function clone_reddit_repo_branch {
    local destination=$REDDIT_SRC/${1}
    local repository_url=https://github.com/${2}.git

    if [ ! -d $destination ]; then
        sudo -u $REDDIT_USER -H git clone -b ${3} $repository_url $destination
    fi
}

function clone_reddit_service_repo {
    clone_reddit_repo $1 reddit-archive/reddit-service-$1
}

function clone_reddit_plugin_repo {
    clone_reddit_repo $1 reddit-archive/reddit-plugin-$1
}

clone_reddit_repo_branch reddit libertysoft3/saidit ubuntu18v3
clone_reddit_repo i18n libertysoft3/reddit-i18n
clone_reddit_service_repo websockets
clone_reddit_service_repo activity
clone_reddit_repo snudown libertysoft3/snudown
clone_reddit_repo l2cs kemitche/l2cs

# $REDDIT_PLUGINS repos
clone_reddit_plugin_repo gold

###############################################################################
# Configure Services
###############################################################################

# Configure Cassandra
$RUNDIR/setup_cassandra.sh

# Configure PostgreSQL
$RUNDIR/setup_postgres.sh

# Configure mcrouter
$RUNDIR/setup_mcrouter.sh

# Configure RabbitMQ
$RUNDIR/setup_rabbitmq.sh

###############################################################################
# Install and configure the reddit code
###############################################################################
REDDIT_AVAILABLE_PLUGINS=""
for plugin in $REDDIT_PLUGINS; do
    if [ -d $REDDIT_SRC/$plugin ]; then
        if [[ -z "$REDDIT_PLUGINS" ]]; then
            REDDIT_AVAILABLE_PLUGINS+="$plugin"
        else
            REDDIT_AVAILABLE_PLUGINS+=" $plugin"
        fi
        echo "plugin $plugin found"
    else
        echo "plugin $plugin not found"
    fi
done

function install_reddit_repo {
    pushd $REDDIT_SRC/$1
    copy_service $REDDIT_SRC/$1
    sudo -u $REDDIT_USER python setup.py build
    python setup.py develop --no-deps
    popd
}

install_reddit_repo l2cs
install_reddit_repo reddit/r2
install_reddit_repo i18n

# TODO PORT - reddit-plugin-gold has an upstart folder, need 'services'
for plugin in $REDDIT_AVAILABLE_PLUGINS; do
    copy_upstart $REDDIT_SRC/$plugin
    install_reddit_repo $plugin
done
install_reddit_repo websockets
install_reddit_repo activity
install_reddit_repo snudown

# $REDDIT_PLUGINS repos
install_reddit_repo gold

# generate binary translation files from source
sudo -u $REDDIT_USER make -C $REDDIT_SRC/i18n clean all

# this builds static files and should be run *after* languages are installed
# so that the proper language-specific static files can be generated and after
# plugins are installed so all the static files are available.
pushd $REDDIT_SRC/reddit/r2
sudo -u $REDDIT_USER make clean pyx

plugin_str=$(echo -n "$REDDIT_AVAILABLE_PLUGINS" | tr " " ,)
if [ ! -f development.update ]; then
    cat > development.update <<DEVELOPMENT
# after editing this file, run "make ini" to
# generate a new development.ini
[secrets]
# the tokens in this section are base64 encoded
# SECRET = YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXowMTIzNDU2Nzg5
# FEEDSECRET = YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXowMTIzNDU2Nzg5
# ADMINSECRET = YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXowMTIzNDU2Nzg5
# websocket = YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXowMTIzNDU2Nzg5
# media_embed = YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXowMTIzNDU2Nzg5
# action_name = YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXowMTIzNDU2Nzg5
# email_notifications = YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXowMTIzNDU2Nzg5
# cache_poisoning = YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXowMTIzNDU2Nzg5
# adserver_click_url_secret = YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXowMTIzNDU2Nzg5
# modmail_email_secret = YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXowMTIzNDU2Nzg5
# request_signature_secret = YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXowMTIzNDU2Nzg5

[DEFAULT]
# global debug flag -- displays pylons stacktrace rather than 500 page on error when true
# WARNING: a pylons stacktrace allows remote code execution. Make sure this is false
# if your server is publicly accessible.
debug = true
uncompressedJS = true
sqlprinting = false
profile_directory =

disable_ads = true
disable_captcha = true
disable_ratelimit = true
disable_require_admin_otp = true

domain = $REDDIT_DOMAIN
oauth_domain = $REDDIT_DOMAIN
https_endpoint = https://%(domain)s

plugins = $plugin_str

media_provider = filesystem
media_fs_root = /srv/www/media
media_fs_base_url_http = http://%(domain)s/media/

min_membership_create_community = 0

# the default subreddit for submissions and wiki. created by inject_test_data.py
default_sr = frontpage

# account name that AutoModerator actions will be done by
automoderator_account = automoderator

[server:main]
port = 8001

[live_config]
# Specify global admins and permissions, each user should have one of admin, sponsor, or employee as their permission level
employees = saidit:admin
feature_force_https = on

create_sr_account_age_days = 0
create_sr_link_karma = 0
create_sr_comment_karma = 0
create_sr_ratelimit_once_per_days = 0
DEVELOPMENT
    chown $REDDIT_USER development.update
else
    sed -i "s/^plugins = .*$/plugins = $plugin_str/" $REDDIT_SRC/reddit/r2/development.update
    sed -i "s/^domain = .*$/domain = $REDDIT_DOMAIN/" $REDDIT_SRC/reddit/r2/development.update
    sed -i "s/^oauth_domain = .*$/oauth_domain = $REDDIT_DOMAIN/" $REDDIT_SRC/reddit/r2/development.update
fi

sudo -u $REDDIT_USER make ini

if [ ! -L run.ini ]; then
    sudo -u $REDDIT_USER ln -nsf development.ini run.ini
fi

popd

###############################################################################
# some useful helper scripts
###############################################################################
function helper-script() {
    cat > $1
    chmod 755 $1
}

# TODO PORT - systemd
helper-script /usr/local/bin/reddit-run <<REDDITRUN
#!/bin/bash
exec paster --plugin=r2 run $REDDIT_SRC/reddit/r2/run.ini "\$@"
REDDITRUN

helper-script /usr/local/bin/reddit-shell <<REDDITSHELL
#!/bin/bash
exec paster --plugin=r2 shell $REDDIT_SRC/reddit/r2/run.ini
REDDITSHELL

helper-script /usr/local/bin/reddit-start <<REDDITSTART
#!/bin/bash
initctl emit reddit-start
REDDITSTART

helper-script /usr/local/bin/reddit-stop <<REDDITSTOP
#!/bin/bash
initctl emit reddit-stop
REDDITSTOP

helper-script /usr/local/bin/reddit-restart <<REDDITRESTART
#!/bin/bash
initctl emit reddit-restart TARGET=${1:-all}
REDDITRESTART

helper-script /usr/local/bin/reddit-flush <<REDDITFLUSH
#!/bin/bash
echo flush_all | nc localhost 11211
REDDITFLUSH

helper-script /usr/local/bin/reddit-serve <<REDDITSERVE
#!/bin/bash
exec paster serve --reload $REDDIT_SRC/reddit/r2/run.ini
REDDITSERVE

###############################################################################
# pixel and click server
###############################################################################
mkdir -p /var/opt/reddit/
chown $REDDIT_USER:$REDDIT_GROUP /var/opt/reddit/

mkdir -p /srv/www/pixel
chown $REDDIT_USER:$REDDIT_GROUP /srv/www/pixel
cp $REDDIT_SRC/reddit/r2/r2/public/static/pixel.png /srv/www/pixel

if [ ! -f /etc/gunicorn.d/click.conf ]; then
    cat > /etc/gunicorn.d/click.conf <<CLICK
CONFIG = {
    "mode": "wsgi",
    "working_dir": "$REDDIT_SRC/reddit/scripts",
    "user": "$REDDIT_USER",
    "group": "$REDDIT_USER",
    "args": (
        "--bind=unix:/var/opt/reddit/click.sock",
        "--workers=1",
        "tracker:application",
    ),
}
CLICK
fi

# TODO PORT
# service gunicorn start

###############################################################################
# nginx
###############################################################################

mkdir -p /srv/www/media
chown $REDDIT_USER:$REDDIT_GROUP /srv/www/media

cat > /etc/nginx/conf.d/reddit.conf <<NGINX
log_format directlog '\$remote_addr - \$remote_user [\$time_local] '
                      '"\$request_method \$request_uri \$server_protocol" \$status \$body_bytes_sent '
                      '"\$http_referer" "\$http_user_agent"';
NGINX

cat > /etc/nginx/sites-available/reddit-media <<MEDIA
server {
    listen 9000;

    expires max;

    location /media/ {
        alias /srv/www/media/;
    }
}
MEDIA

cat > /etc/nginx/sites-available/reddit-pixel <<PIXEL
upstream click_server {
  server unix:/var/opt/reddit/click.sock fail_timeout=0;
}

server {
  listen 8082;
  access_log      /var/log/nginx/traffic/traffic.log directlog;

  location / {

    rewrite ^/pixel/of_ /pixel.png;

    add_header Last-Modified "";
    add_header Pragma "no-cache";

    expires -1;
    root /srv/www/pixel/;
  }

  location /click {
    proxy_pass http://click_server;
  }
}
PIXEL

cat > /etc/nginx/sites-available/reddit-ssl <<SSL
map \$http_upgrade \$connection_upgrade {
  default upgrade;
  ''      close;
}

server {
    listen 443;

    ssl on;
    ssl_certificate /etc/ssl/certs/ssl-cert-snakeoil.pem;
    ssl_certificate_key /etc/ssl/private/ssl-cert-snakeoil.key;
    ssl_dhparam /etc/nginx/dhparam.pem;

    # Support TLSv1 for Android 4.3 (Samsung Galaxy S3) https://www.ssllabs.com/ssltest/viewClient.html?name=Android&version=4.3&key=61
    # ciphers from https://cipherli.st legacy / old list
    ssl_protocols TLSv1 TLSv1.1 TLSv1.2 TLSv1.3;
    # ssl_ciphers "EECDH+AESGCM:EDH+AESGCM:AES256+EECDH:AES256+EDH:ECDHE-RSA-AES128-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA128:DHE-RSA-AES128-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES128-GCM-SHA128:ECDHE-RSA-AES128-SHA384:ECDHE-RSA-AES128-SHA128:ECDHE-RSA-AES128-SHA:ECDHE-RSA-AES128-SHA:DHE-RSA-AES128-SHA128:DHE-RSA-AES128-SHA128:DHE-RSA-AES128-SHA:DHE-RSA-AES128-SHA:ECDHE-RSA-DES-CBC3-SHA:EDH-RSA-DES-CBC3-SHA:AES128-GCM-SHA384:AES128-GCM-SHA128:AES128-SHA128:AES128-SHA128:AES128-SHA:AES128-SHA:DES-CBC3-SHA:HIGH:!aNULL:!eNULL:!EXPORT:!DES:!MD5:!PSK:!RC4";
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:1m;
    ssl_stapling on;
    ssl_stapling_verify on;
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload";
    # reddit code manages these headers
    # add_header X-Frame-Options DENY;
    # add_header X-Content-Type-Options nosniff;
    # add_header X-XSS-Protection "1; mode=block";

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$http_host;
        proxy_http_version 1.1;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_pass_header Server;

        # allow websockets through if desired
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }
}
SSL

# SSL stuff
openssl dhparam -out /etc/nginx/dhparam.pem 2048

# remove the default nginx site that may conflict with haproxy
rm -rf /etc/nginx/sites-enabled/default
# put our config in place
ln -nsf /etc/nginx/sites-available/reddit-media /etc/nginx/sites-enabled/
ln -nsf /etc/nginx/sites-available/reddit-pixel /etc/nginx/sites-enabled/
ln -nsf /etc/nginx/sites-available/reddit-ssl /etc/nginx/sites-enabled/

# make the pixel log directory
mkdir -p /var/log/nginx/traffic

# link the ini file for the Flask click tracker
ln -nsf $REDDIT_SRC/reddit/r2/development.ini $REDDIT_SRC/reddit/scripts/production.ini

service nginx restart

###############################################################################
# haproxy
###############################################################################
if [ -e /etc/haproxy/haproxy.cfg ]; then
    BACKUP_HAPROXY=$(mktemp /etc/haproxy/haproxy.cfg.XXX)
    echo "Backing up /etc/haproxy/haproxy.cfg to $BACKUP_HAPROXY"
    cat /etc/haproxy/haproxy.cfg > $BACKUP_HAPROXY
fi

# make sure haproxy is enabled
cat > /etc/default/haproxy <<DEFAULT
ENABLED=1
DEFAULT

# configure haproxy
cat > /etc/haproxy/haproxy.cfg <<HAPROXY
global
    maxconn 350

frontend frontend
    mode http

    bind 0.0.0.0:80
    bind 127.0.0.1:8080

    timeout client 24h
    option forwardfor except 127.0.0.1
    option httpclose

    # make sure that requests have x-forwarded-proto: https iff tls
    reqidel ^X-Forwarded-Proto:.*
    acl is-ssl dst_port 8080
    reqadd X-Forwarded-Proto:\ https if is-ssl

    # send websockets to the websocket service
    acl is-websocket hdr(Upgrade) -i WebSocket
    use_backend websockets if is-websocket

    # send media stuff to the local nginx
    acl is-media path_beg /media/
    use_backend media if is-media

    # send pixel stuff to local nginx
    acl is-pixel path_beg /pixel/
    acl is-click path_beg /click
    use_backend pixel if is-pixel || is-click

    default_backend reddit

backend reddit
    mode http
    timeout connect 4000
    timeout server 30000
    timeout queue 60000
    balance roundrobin

    server app01-8001 localhost:8001 maxconn 30

backend websockets
    mode http
    timeout connect 4s
    timeout server 24h
    balance roundrobin

    server websockets localhost:9001 maxconn 250

backend media
    mode http
    timeout connect 4000
    timeout server 30000
    timeout queue 60000
    balance roundrobin

    server nginx localhost:9000 maxconn 20

backend pixel
    mode http
    timeout connect 4000
    timeout server 30000
    timeout queue 60000
    balance roundrobin

    server nginx localhost:8082 maxconn 20
HAPROXY

# this will start it even if currently stopped
service haproxy restart

###############################################################################
# websocket service
###############################################################################
# TODO PORT???
if [ ! -f /etc/init/reddit-websockets.conf ]; then
    cat > /etc/init/reddit-websockets.conf << UPSTART_WEBSOCKETS
description "websockets service"

stop on runlevel [!2345] or reddit-restart all or reddit-restart websockets
start on runlevel [2345] or reddit-restart all or reddit-restart websockets

respawn
respawn limit 10 5
kill timeout 15

limit nofile 65535 65535

exec baseplate-serve2 --bind localhost:9001 $REDDIT_SRC/websockets/example.ini
UPSTART_WEBSOCKETS
fi

# service reddit-websockets restart

###############################################################################
# activity service
###############################################################################
# TODO PORT
if [ ! -f /etc/init/reddit-activity.conf ]; then
    cat > /etc/init/reddit-activity.conf << UPSTART_ACTIVITY
description "activity service"

stop on runlevel [!2345] or reddit-restart all or reddit-restart activity
start on runlevel [2345] or reddit-restart all or reddit-restart activity

respawn
respawn limit 10 5
kill timeout 15

exec baseplate-serve2 --bind localhost:9002 $REDDIT_SRC/activity/example.ini
UPSTART_ACTIVITY
fi

# service reddit-activity restart

###############################################################################
# geoip service
###############################################################################
# TODO PORT
if [ ! -f /etc/gunicorn.d/geoip.conf ]; then
    cat > /etc/gunicorn.d/geoip.conf <<GEOIP
CONFIG = {
    "mode": "wsgi",
    "working_dir": "$REDDIT_SRC/reddit/scripts",
    "user": "$REDDIT_USER",
    "group": "$REDDIT_USER",
    "args": (
        "--bind=127.0.0.1:5000",
        "--workers=1",
         "--limit-request-line=8190",
         "geoip_service:application",
    ),
}
GEOIP
fi

# service gunicorn start

###############################################################################
# Job Environment
###############################################################################
CONSUMER_CONFIG_ROOT=$REDDIT_HOME/consumer-count.d

if [ ! -f /etc/default/reddit ]; then
    cat > /etc/default/reddit <<DEFAULT
export REDDIT_SRC=$REDDIT_SRC
export REDDIT_ROOT=$REDDIT_SRC/reddit/r2
export REDDIT_INI=$REDDIT_SRC/reddit/r2/run.ini
export REDDIT_USER=$REDDIT_USER
export REDDIT_GROUP=$REDDIT_GROUP
export REDDIT_CONSUMER_CONFIG=$CONSUMER_CONFIG_ROOT
alias wrap-job=$REDDIT_SRC/reddit/scripts/wrap-job
alias manage-consumers=$REDDIT_SRC/reddit/scripts/manage-consumers
DEFAULT
fi

###############################################################################
# Queue Processors
###############################################################################
mkdir -p $CONSUMER_CONFIG_ROOT

function set_consumer_count {
    if [ ! -f $CONSUMER_CONFIG_ROOT/$1 ]; then
        echo $2 > $CONSUMER_CONFIG_ROOT/$1
    fi
}

set_consumer_count search_q 0
set_consumer_count del_account_q 1
set_consumer_count scraper_q 1
set_consumer_count markread_q 1
set_consumer_count commentstree_q 1
set_consumer_count newcomments_q 1
set_consumer_count vote_link_q 1
set_consumer_count vote_comment_q 1
set_consumer_count automoderator_q 1
set_consumer_count butler_q 1
set_consumer_count author_query_q 1
set_consumer_count subreddit_query_q 1
set_consumer_count domain_query_q 1

chown -R $REDDIT_USER:$REDDIT_GROUP $CONSUMER_CONFIG_ROOT/

###############################################################################
# Complete plugin setup, if setup.sh exists
###############################################################################
for plugin in $REDDIT_AVAILABLE_PLUGINS; do
    if [ -x $REDDIT_SRC/$plugin/setup.sh ]; then
        echo "Found setup.sh for $plugin; running setup script"
        $REDDIT_SRC/$plugin/setup.sh $REDDIT_SRC $REDDIT_USER
    fi
done

###############################################################################
# Start everything up
###############################################################################

# the initial database setup should be done by one process rather than a bunch
# vying with eachother to get there first
reddit-run -c 'print "ok done"'

# ok, now start everything else up
systemctl daemon-reload
systemctl start reddit
systemctl enable reddit

###############################################################################
# Cron Jobs
###############################################################################
# TODO PORT - /sbin/start does not exist
if [ ! -f /etc/cron.d/reddit ]; then
    cat > /etc/cron.d/reddit <<CRON
0    3 * * * root /sbin/start --quiet reddit-job-update_sr_names
30  16 * * * root /sbin/start --quiet reddit-job-update_reddits
0    * * * * root /sbin/start --quiet reddit-job-update_promos
*/5  * * * * root /sbin/start --quiet reddit-job-clean_up_hardcache
*/2  * * * * root /sbin/start --quiet reddit-job-broken_things
*/2  * * * * root /sbin/start --quiet reddit-job-rising
0    * * * * root /sbin/start --quiet reddit-job-trylater
*/15 * * * * root /sbin/start --quiet reddit-job-update_popular_subreddits
0    * * * * root /sbin/start --quiet reddit-job-hourly_traffic
0    * * * * root /sbin/start --quiet reddit-job-subscribers

# liveupdate plugin
#*    * * * * root /sbin/start --quiet reddit-job-liveupdate_activity

# gold plugin
#0    0 * * * root /sbin/start --quiet reddit-job-update_gold_users

# jobs that recalculate time-limited listings (e.g. top this year)
# must match 'db_pass' in development.update
PGPASSWORD=password
*/15 * * * * $REDDIT_USER $REDDIT_SRC/reddit/scripts/compute_time_listings link year "['hour', 'day', 'week', 'month', 'year']" 2>&1 | /usr/bin/logger -t compute_time_listings_link
*/15 * * * * $REDDIT_USER $REDDIT_SRC/reddit/scripts/compute_time_listings comment year "['hour', 'day', 'week', 'month', 'year']" 2>&1 | /usr/bin/logger -t compute_time_listings_comment

# disabled by default, uncomment if you need these jobs
#*    * * * * root /sbin/start --quiet reddit-job-email
#*/15  * * * * root /sbin/start reddit-job-update_trending_subreddits

# solr search
*/15  * * * * root /sbin/start --quiet reddit-job-solr_subreddits
*/5 * * * * root /sbin/start --quiet reddit-job-solr_links
CRON
fi

###############################################################################
# Finished with install script
###############################################################################
# print this out here. if vagrant's involved, it's gonna do more steps
# afterwards and then re-run this script but that's ok.
$RUNDIR/done.sh
