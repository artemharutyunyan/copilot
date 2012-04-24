#!/bin/sh

echo "This script will download and install software packages required for Co-Pilot's Monitoring system."
echo "For more information please refer to Co-Pilot's Technical Report (http://j.mp/copilot-tech-report)"
echo "You will be asked for your root password during the process."
echo
echo " - Press return key to continue -"
read

echo "Installing pycairo..."
sudo conary install pycairo

echo "Downloading SQLite..."
wget http://sqlite.org/sqlite-autoconf-3070700.tar.gz
tar xf sqlite-autoconf-3070700.tar.gz
cd sqlite-autoconf-307077
./configure && make
echo "sudo make install sqlite:"
sudo make install

cd ..

echo "Downloading easy_install..."
wget http://pypi.python.org/packages/2.4/s/setuptools/setuptools-0.6c11-py2.4.egg
echo "Installing easy_install..."
sudo sh setuptools-0.6c11-py2.4.egg

echo "Installing Python libraries and applications..."
sudo easy_install \
ctypes \
pysqlite \
http://cernvm-copilot-monitor.googlecode.com/files/Twisted-10.2.0.tar.bz2
django \
https://github.com/tilgovi/gunicorn/tarball/0.11.0 \
http://cernvm-copilot-monitor.googlecode.com/files/graphite-280711.tar.gz

echo "Downloading gevent..."
wget http://pypi.python.org/packages/source/g/gevent/gevent-0.13.6.tar.gz
tar xf gevent-0.13.6.tar.gz && cd gevent-0.13.6
python fetch_libevent.py
echo "Installing gevent..."
sudo python setup.py install

echo "Done!"
