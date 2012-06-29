import os
from distutils.core import setup
from setuptools import find_packages

static = {}

for root, dirs, files in os.walk('copilot_dashboard/dashboard/static'):
  for filename in files:
    filepath = os.path.join(root, filename)

    if root not in static:
      static[root] = []

    static[root].append(filepath)

setup(
  name='copilot_dashboard',
  version='0.1.0',
  packages=find_packages(),
  scripts=['bin/copilot-dashboard'],
  url='https://github.com/josip/copilot/tree/master/src/copilot-dashboard',
  license='See COPYING in the root folder',
  description='Graphical interface for the Co-Pilot Monitoring system',
  long_description=open('README').read(),
  zip_safe=False,
  data_files=static.items(),
  install_requires=[
    "Django == 1.3",
    "pymongo == 2.2",
    "httplib2 == 0.7.4"
  ]
)
