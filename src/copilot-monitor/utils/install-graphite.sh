#!/bin/sh

echo "This script will download and install software packages required for Co-Pilot's Monitoring system."
echo "For more information please refer to Co-Pilot's Technical Report (http://j.mp/copilot-tech-report)"
echo "You will be asked for your root password during the process."
echo
echo " - Press return key to continue -"
read

echo "Installing pycairo..."
sudo conary install pycairo

CWD=`dir`

echo "Downloading SQLite..."
wget http://sqlite.org/sqlite-autoconf-3070700.tar.gz
tar xf sqlite-autoconf-3070700.tar.gz
cd sqlite-autoconf-3070700
./configure --prefix=/usr && make && sudo make install
cd ..

echo "Downloading easy_install..."
wget http://pypi.python.org/packages/2.4/s/setuptools/setuptools-0.6c11-py2.4.egg
echo "Installing easy_install..."
sudo sh setuptools-0.6c11-py2.4.egg

echo "Installing Python libraries and applications..."
sudo easy_install \
ctypes \
http://pysqlite.googlecode.com/files/pysqlite-2.6.3.tar.gz \
http://pypi.python.org/packages/source/h/hashlib/hashlib-20081119.zip \
http://pypi.python.org/packages/source/z/zope.interface/zope.interface-3.7.0.tar.gz \
http://pypi.python.org/packages/source/T/Twisted/Twisted-11.1.0.tar.bz2 \
https://www.djangoproject.com/download/1.3.1/tarball/ \
http://django-tagging.googlecode.com/files/django-tagging-0.3.1.tar.gz \
http://github.com/tilgovi/gunicorn/tarball/0.11.0

echo "Installing carbon, whisper and graphite-web..."

# Official repository currently ships with a bug
#wget --no-check-certificate https://github.com/downloads/graphite-project/carbon/carbon-0.9.10.tar.gz
#tar xf carbon-0.9.10.tar.gz && cd carbon-0.9.10
wget --no-check-certificate -O carbon.zip https://github.com/josip/carbon/zipball/master
unzip carbon.zip && cd josip-carbon-*
sudo python setup.py install
cd ..

wget --no-check-certificate https://github.com/downloads/graphite-project/whisper/whisper-0.9.10.tar.gz
tar xf whisper-0.9.10.tar.gz && cd whisper-0.9.10
sudo python setup.py install
cd ..

wget --no-check-certificate https://github.com/downloads/graphite-project/graphite-web/graphite-web-0.9.10.tar.gz
tar xf graphite-web-0.9.10.tar.gz && cd graphite-web-0.9.10
sudo python setup.py install
cd ..

echo "Downloading gevent..."
wget http://pypi.python.org/packages/source/g/gevent/gevent-0.13.6.tar.gz
tar xf gevent-0.13.6.tar.gz && cd gevent-0.13.6
python fetch_libevent.py
echo "Installing gevent..."
sudo python setup.py install

echo "Initialising Graphite's database"
cd /opt/graphite/webapp/graphite
sudo python manage.py syncdb

cd $CWD
chmod +x start-graphite.sh
chmod +x stop-graphite.sh

echo "*****************"
echo "That's it!"
echo "Your Graphite installation is... almost ready!"
echo " - change the ownership of /opt/graphite"
echo " - take a look at files in the config/ directory"
echo " - adjust them to your needs and copy them to /opt/graphite/config"
echo " - take a look at /opt/graphite/config/carbon.conf.example"
echo "To start/stop Graphite, use scripts provided in this directory"
echo "*****************"
