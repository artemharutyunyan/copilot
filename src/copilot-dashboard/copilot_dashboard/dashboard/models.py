import datetime
import time
from pymongo import Connection, GEO2D, ASCENDING, DESCENDING
from bson.code import Code
from bson.objectid import ObjectId
from bson.son import SON
from copilot_dashboard.settings import SETTINGS

_mongo_conn = Connection(SETTINGS['MONGODB_HOST'], int(SETTINGS['MONGODB_PORT']))
#_mongo_version = map(int, _mongo_conn.server_info()['version'])
_db = _mongo_conn[SETTINGS['MONGODB_DB']]
_collections = {}

def get_collection(collection):
  global _db
  global _collections

  if collection not in _collections:
    _collections[collection] = _db[collection]

  return _collections[collection]

def get_connection(id):
  global _connections
  return _connections.find_one(ObjectId(id), {'_id': 0, 'loc': 0})

def get_contributions(id, days=7, _attempt=1):
  coll = get_collection('contrib_daily')
  now = datetime.datetime.utcnow()
  start_date = datetime.datetime(now.year, now.month, now.day) - datetime.timedelta(days=days)

  # this will fetch stats for last N days
  docs = coll.find({
    '_id': {'$gt': "%s::%4d-%02d-%02d" % (id, start_date.year, start_date.month, start_date.day)},
  }).sort('_id', direction=ASCENDING)

  (last_gen, contribs) = _group_contribs(docs)

  # refreshes stats if they weren't yet refreshed today for the particular agent
  if last_gen < today() and _attempt == 1:
    if last_gen < start_date:
      # if the last update happened before the required time frame
      # then we're going to cheat and we won't generate
      # the data for the earlier period
      update_contrib_stats(id, start_date - datetime.timedelta(days=1))
    else:
      update_contrib_stats(id, last_gen)
    return get_contributions(id, days, _attempt + 1)
  else:
    return contribs

def update_contrib_stats(id, start_date):
  global _connections

  mapper = Code("""
    function () {
      var ts = new Date(this.created_at),
          month = ts.getMonth() + 1,
          date = ts.getDate();
      month = month < 10 ? "0" + month : month;
      date = date < 10 ? "0" + date : date;
      emit(this.agent_data.id + '::' + [ts.getFullYear(), month, date].join('-'), {
        succeeded: this.succeeded_jobs,
        failed: this.failed_jobs,
        cputime: this.contributed_time,
        generated_at: new Date()
      });
    }
    """)
  reducer = Code("""
      function (key, values) {
      var succeeded = 0,
          failed = 0
          cputime = 0,
          n = values.length;

      while(n--) {
        var value = values[n];
        succeeded += value.succeeded;
        failed += value.failed;
        cputime += value.cputime;
      }

      return {
        succeeded: succeeded,
        failed: failed,
        cputime: cputime,
        generated_at: new Date()
      };
    }
    """)

  _connections.map_reduce(mapper, reducer,
                          out=SON([('reduce', 'contrib_daily')]),
                          query={'agent_data.component': 'agent',
                                 'agent_data.id': id,
                                 'created_at': {'$gt': start_date,
                                                '$lt': today()}
                                })


def _group_contribs(docs):
  """
  Prepares data for graph rendering.

  [{failed: X, ...}, {failed:Y, ...}, ...] => {failed: [[date, X], [date, Y], ...], ...}
  """
  contribs = {'succeeded': [], 'failed': [], 'cputime': []}
  # system wasn't in use before and Mogo has problems with timestamp '0'
  last_gen = datetime.datetime(2012, 7, 1)
  for doc in docs:
    (year, month, day) = map(int, str(doc['_id']).split('::')[1].split('-'))
    date = datetime.datetime(year, month, day)
    ts = time.mktime(date.timetuple())
    for k in ['succeeded', 'failed', 'cputime']:
      contribs[k].append([ts*1000, doc['value'][k]])
    last_gen = doc['value']['generated_at']

  return (last_gen, contribs)

def today():
  now = datetime.datetime.utcnow()
  return now - datetime.timedelta(hours=now.hour,
                                   minutes=now.minute,
                                   seconds=now.second,
                                   microseconds=now.microsecond)

_connections = get_collection('connections')
_connections.ensure_index([('loc', GEO2D)])
_connections.ensure_index([('updated_at', 1)])
_connections.ensure_index([('agent_data.uuid', 1)])
_connections.ensure_index([('agent_data.component', 1)])
