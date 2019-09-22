#!/bin/bash
# The contents of this file are subject to the Common Public Attribution
# License Version 1.0. (the "License"); you may not use this file except in
# compliance with the License. You may obtain a copy of the License at
# http://code.reddit.com/LICENSE. The License is based on the Mozilla Public
# License Version 1.1, but Sections 14 and 15 have been added to cover use of
# software over a computer network and provide for limited attribution for the
# Original Developer. In addition, Exhibit A has been modified to be consistent
# with Exhibit B.
#
# Software distributed under the License is distributed on an "AS IS" basis,
# WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License for
# the specific language governing rights and limitations under the License.
#
# The Original Code is reddit.
#
# The Original Developer is the Initial Developer.  The Initial Developer of
# the Original Code is reddit Inc.
#
# All portions of the code written by reddit are Copyright (c) 2006-2015 reddit
# Inc. All Rights Reserved.
###############################################################################

# load configuration
RUNDIR=$(dirname $0)
source $RUNDIR/install.cfg

###############################################################################
# Configure RabbitMQ
###############################################################################
if ! sudo rabbitmqctl list_vhosts | egrep "^/$"
then
    sudo rabbitmqctl add_vhost /
fi

if ! sudo rabbitmqctl list_users | egrep "^reddit"
then
    sudo rabbitmqctl add_user reddit reddit
fi

sudo rabbitmqctl set_permissions -p / reddit ".*" ".*" ".*"
sudo rabbitmq-plugins enable rabbitmq_management

# Fix Ubuntu 18 bug https://bugs.launchpad.net/ubuntu/+source/rabbitmq-server/+bug/1784757
sudo sed -i 's/rabbitmqctl stop/rabbitmqctl shutdown/g' /lib/systemd/system/rabbitmq-server.service
sudo systemctl daemon-reload

sudo systemctl restart rabbitmq-server
