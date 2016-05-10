#!/bin/bash

set -e
shopt -s expand_aliases

. /etc/lsb-release

MYUSER=cif
MYGROUP=cif
VER=$DISTRIB_RELEASE

if [ `whoami` != 'root' ]; then
    echo 'this script must be run as root'
    exit 0
fi

if [ -d /opt/cif ]; then
    bash upgrade.sh
fi

echo "Acquire::ForceIPv4 \"true\";" > /etc/apt/apt.conf.d/99force-ipv4

apt-get update
apt-get install -qq software-properties-common python-software-properties

if [ "$VER" = "14.04" -a ! -f /etc/apt/sources.list.d/chris-lea-zeromq-trusty.list ]; then
    echo 'adding updated zmq repo....'
    echo "yes" | add-apt-repository "ppa:chris-lea/zeromq"
    echo "yes" | add-apt-repository "ppa:maxmind/ppa"
fi

if [ "$VER" = "16.04" -a -z "$(grep -e '^deb .*archive.ubuntu.com/ubuntu/.* xenial .*multiverse.*$' /etc/apt/sources.list)" \
    -a ! -f /etc/apt/sources.list.d/multiverse.list ]; then
    echo "deb http://archive.ubuntu.com/ubuntu/ xenial multiverse" >> /etc/apt/sources.list.d/multiverse.list
fi

wget -O - https://packages.elasticsearch.org/GPG-KEY-elasticsearch | apt-key add -
if [ -f /etc/apt/sources.list.d/elasticsearch.list ]; then
    echo "sources.list.d/elasticsearch.list already exists, skipping..."
else
    echo "deb http://packages.elasticsearch.org/elasticsearch/1.7/debian stable main" >> /etc/apt/sources.list.d/elasticsearch.list
fi

debconf-set-selections <<< "postfix postfix/mailname string localhost"
debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Internet Site'"

packages="monit geoipupdate curl build-essential libmodule-build-perl libssl-dev elasticsearch apache2 libapache2-mod-perl2 curl mailutils build-essential git-core automake rng-tools libtool pkg-config vim htop bind9 libzmq3-dev libffi6 libmoose-perl libmouse-perl libanyevent-perl liblwp-protocol-https-perl libxml2-dev libexpat1-dev libgeoip-dev geoip-bin python-dev starman ntp"
if [ "$VER" = "14.04" ]; then
    packages="$packages openjdk-7-jre-headless"
elif [ "$VER" = "16.04" ]; then
    packages="$packages openjdk-8-jre-headless"
fi

apt-get update
apt-get install -y $packages

# set up the firewall
bash firewall.sh

#if [ ! -d /usr/share/elasticsearch/plugins/marvel ]; then
#    echo 'installing marvel for elasticsearch...'
#    /usr/share/elasticsearch/bin/plugin -i elasticsearch/marvel/latest
#fi

echo 'installing cpanm...'
curl -L https://cpanmin.us | perl - App::cpanminus
alias cpanm='cpanm --wget --mirror https://cpan.metacpan.org --skip-installed'

cpanm Regexp::Common
cpanm Moo@1.007000
cpanm Mouse@2.4.2
cpanm ZMQ::FFI@0.17
cpanm --force --notest https://github.com/csirtgadgets/ZMQx-Class/archive/master.tar.gz
cpanm Log::Log4perl@1.44
cpanm Test::Exception@0.32
cpanm MaxMind::DB::Reader@0.050005
cpanm GeoIP2@0.040005
cpanm Hijk@0.19
# TODO: remove this when p5-cif-sdk release is updated
if [ "$VER" = "16.04" ]; then
    cpanm https://github.com/csirtgadgets/p5-cif-sdk/archive/master.tar.gz
else
    cpanm https://github.com/csirtgadgets/p5-cif-sdk/archive/2.00_37.tar.gz
fi
cpanm https://github.com/kraih/mojo/archive/v5.82.tar.gz
cpanm Search::Elasticsearch@1.19
cpanm http://search.cpan.org/CPAN/authors/id/H/HA/HAARG/local-lib-2.000015.tar.gz

echo 'HRNGDEVICE=/dev/urandom' >> /etc/default/rng-tools
service rng-tools restart

bash apache.sh

if [ -z `getent passwd $MYUSER` ]; then
    echo "adding user: $MYUSER"
    useradd $MYUSER -m -s /bin/bash
    adduser www-data $MYUSER
fi

echo 'starting elastic search'
update-rc.d elasticsearch defaults 95 10
service elasticsearch restart

set +e
echo 'removing old elastic search templates'
curl -XDELETE http://localhost:9200/_template/template_cif_observables > /dev/null 2>&1
curl -XDELETE http://localhost:9200/_template/template_cif_tokens > /dev/null 2>&1
set -e

cd ../../../

./configure --enable-geoip --sysconfdir=/etc/cif --localstatedir=/var --prefix=/opt/cif
make && make deps NOTESTS=-n
make test
make install
make fixperms
make elasticsearch

if [ ! -f /etc/default/cif ]; then
    echo 'setting /etc/default/cif'
    cp ./hacking/packaging/ubuntu/default/cif /etc/default/cif
fi

if [ ! -f /home/cif/.profile ]; then
    touch /home/cif/.profile
    chown $MYUSER:$MYGROUP /home/cif/.profile
fi

mkdir -p /var/smrt/cache
chown -R $MYUSER:$MYGROUP /var/smrt

if [ -z `grep -l '/opt/cif/bin' /home/cif/.profile` ]; then
    MYPROFILE=/home/$MYUSER/.profile
    echo "" >> $MYPROFILE
    echo "# automatically generated by CIF installation" >> $MYPROFILE
    echo 'PATH=/opt/cif/bin:$PATH' >> $MYPROFILE
fi

if [ ! -f /etc/cif/cif-smrt.yml ]; then
    echo 'setting up /etc/cif/cif-smrt.yml config...'
    /opt/cif/bin/cif-tokens --username cif-smrt --new --write --generate-config-remote http://localhost:5000 --generate-config-path /etc/cif/cif-smrt.yml
    chown cif:cif /etc/cif/cif-smrt.yml
    chmod 660 /etc/cif/cif-smrt.yml
fi

if [ ! -f /etc/cif/cif-worker.yml ]; then
    echo 'setting up /etc/cif/cif-worker.yml config...'
    /opt/cif/bin/cif-tokens --username cif-worker --new --read --write --generate-config-remote tcp://localhost:4961 --generate-config-path /etc/cif/cif-worker.yml
    chown cif:cif /etc/cif/cif-worker.yml
    chmod 660 /etc/cif/cif-worker.yml
fi

if [ ! -f ~/.cif.yml ]; then
    echo 'setting up ~/.cif.yml config for user: root@localhost...'
    /opt/cif/bin/cif-tokens --username root@localhost --new --read --write --generate-config-remote https://localhost --generate-config-path ~/.cif.yml
    chmod 660 ~/.cif.yml
fi

echo "setting up log rotation"
cp ./hacking/platforms/ubuntu/cif.logrotated /etc/logrotate.d/cif

echo 'setting default cif-starman.conf'
cp ./hacking/platforms/ubuntu/cif-starman.conf /etc/cif/

echo 'copying init.d scripts...'
/bin/cp ./hacking/packaging/ubuntu/init.d/cif-smrt /etc/init.d/
/bin/cp ./hacking/packaging/ubuntu/init.d/cif-router /etc/init.d/
/bin/cp ./hacking/packaging/ubuntu/init.d/cif-starman /etc/init.d/
/bin/cp ./hacking/packaging/ubuntu/init.d/cif-worker /etc/init.d/
/bin/cp ./hacking/packaging/ubuntu/init.d/cif-services /etc/init.d/

update-rc.d cif-services defaults 99 01

cd hacking/platforms/ubuntu
bash bind9.sh
cd ../../../

echo 'staring cif-services...'
service cif-services start

echo 'restarting apache...'
service apache2 restart

echo 'setting up geoipupdate...'
cp ./hacking/platforms/ubuntu/GeoIP.conf /etc/
cp ./hacking/platforms/ubuntu/geoipupdate.cron /etc/cron.monthly/geoipupdate.sh
chmod 755 /etc/cron.monthly/geoipupdate.sh

# work-around for cif-router mem leak
# https://github.com/csirtgadgets/massive-octo-spice/issues/155
# it's crappy, but its a work-around atm, perl just doesn't like to give up memory
cp ./hacking/platforms/ubuntu/cif-router.cron /etc/cron.weekly/cif-router
chmod 755 /etc/cron.weekly/cif-router

cp ./hacking/platforms/ubuntu/cif-worker.cron /etc/cron.weekly/cif-worker
chmod 755 /etc/cron.weekly/cif-worker

echo 'setting up monit...'
cp ./hacking/platforms/ubuntu/cif.monit /etc/monit/conf.d/cif
cp ./hacking/platforms/ubuntu/elasticsearch.monit /etc/monit/conf.d/elasticsearch
echo 'restarting monit...'
service monit restart
