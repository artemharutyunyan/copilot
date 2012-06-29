from pymongo import Connection
from copilot_dashboard.settings import DB

_mongo_conn = Connection(DB['HOST'], DB['PORT'])
_db = _mongo_conn[DB['NAME']]
_collections = {}

def get_collection(collection):
  global _db
  global _collections

  if collection not in _collections:
    _collections[collection] = _db[collection]

  return _collections[collection]
