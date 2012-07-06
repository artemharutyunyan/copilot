import logging

DEBUG = True
TEMPLATE_DEBUG = DEBUG

ADMINS = ()
MANAGERS = ADMINS

SETTINGS = {
  'SERVER_HOST':   '0.0.0.0',
  'SERVER_PORT':   '3274',
  'GRAPHITE_HOST': 'localhost',
  'GRAPHITE_PORT':  8000,
  'MONGODB_HOST':   'localhost',
  'MONGODB_PORT':   27017,
  'MONGODB_DB':     'copilot',
  'GMAPS_KEY':      'SET_YOUR_API_KEY'
}

_imported = False
if not _imported:
  try:
    settingsf = open('/etc/copilot/copilot-dashboard.conf', 'r')
    lines = settingsf.readlines()
    settingsf.close()

    for line in lines:
      line = line.strip()
      if len(line) == 0 or line[0] == '#' or not line.startswith('DASH_'):
        continue

      key, value = map(str.strip, line.split(' '))
      SETTINGS[key.replace('DASH_', '')] = value

      DEBUG = SETTINGS.get('DEBUG', '0') == '1'
    _imported = True
  except IOError, e:
    logging.warning('/etc/copilot/copilot-dashboard.conf file is missing, using default configuration')
