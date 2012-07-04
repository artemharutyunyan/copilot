from pymongo import Connection, GEO2D
from copilot_dashboard.settings import SETTINGS

_mongo_conn = Connection(SETTINGS['MONGODB_HOST'], int(SETTINGS['MONGODB_PORT']))
_db = _mongo_conn[SETTINGS['MONGODB_DB']]
_collections = {}

def get_collection(collection):
  global _db
  global _collections

  if collection not in _collections:
    _collections[collection] = _db[collection]

  return _collections[collection]

_connections = get_collection('connections')
_connections.ensure_index([('loc', GEO2D)])
_connections.ensure_index([('updated_at', 1)])
_connections.ensure_index([('agent_data.uuid', 1)])
