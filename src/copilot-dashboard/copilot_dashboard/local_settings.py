DEBUG = True
TEMPLATE_DEBUG = DEBUG

ADMINS = (
  # ('Your Name', 'your_email@example.com'),
)
MANAGERS = ADMINS

# MongoDB settings
DB = {
  'HOST': '192.168.100.247',   # Location of the host
  'PORT': 27017,               # Port
  'NAME': 'copilot'            # Database
}

# Location of Graphite's web interface
GRAPHITE = {
  'HOST': '192.168.100.247',   # Host
  'PORT':  8000                # Port
}
