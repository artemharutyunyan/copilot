import httplib2
from datetime import datetime
from urllib import urlencode
from random import random

from django.http import HttpRequest, HttpResponse
from django.core.serializers.json import DjangoJSONEncoder
from django.utils import simplejson
from django.conf import settings
import bson.json_util
from bson.objectid import ObjectId

from models import get_collection
from copilot_dashboard.settings import SETTINGS

HTTP = httplib2.Http("/tmp/httplib2-cache")

### Handlers ###
def ping(request):
  """
  GET /api/ping

  Responds with {"ping":"pong"} (HTTP 200) in case the system is working fine

  Status codes:
    * 200 - OK
  """
  return json({'ping': 'pong'})

def stats(request):
  """
  GET /api/stats?target={graphite path}[&from={start timestamp}&until={end timestamp}]

  A simple Graphite proxy

  Status codes:
    * 200 - OK
    * 400 - Missing query parameter
    * 500 - No such data is available
  """
  try:
    path = request.GET['target']
  except KeyError, e:
    return json({'error': True}, 400)

  start = request.GET.get('from', None)
  end = request.GET.get('until', None)
  data = mk_graphite_request(path, start, end)

  return HttpResponse(data, mimetype="application/json")

def connections(request):
  """
  GET /api/connections?from={start}

  Lists all connected machines in specified timeframe.

  Response (JSON):
    [
      {"_id": "Document ID", "loc": [Longitude, Latitude]},
      ...
    ]

  Status codes:
    * 200 - OK
    * 400 - Missing query parameter (from)
  """
  try:
    start = datetime.fromtimestamp(int(request.GET['from'])/1000)
  except KeyError, e:
    return json({'error': True}, 400)

  collection = get_collection('connections')
  docs = []
  #for doc in collection.find({'loc': {'$ne': [0,0]}}, {'_id': 1, 'loc': 1}): # use only for testing
  for doc in collection.find({'updated_at': {'$gte': start}}, {'_id': 1, 'loc': 1}):
    doc['loc'] = [round(coord + random()*0.0004, 5) for coord in doc['loc']]
    docs.append(doc)

  return json(docs)

def connection_info(request, id):
  """
  GET /api/connection/{connection id}

  Responds with all data available for the specified connection (except for document's ID and coordinates).

  Status codes:
    * 200 - OK
    * 404 - Given ID did not match any documents
  """
  collection = get_collection('connections')
  doc = collection.find_one(ObjectId(id), {'_id': 0, 'loc': 0})
  if not doc:
    return json({'error': True}, 404)
  else:
    return json(doc)

### Utilites ###
def mk_graphite_request(path, start, end):
  global HTTP
  query = {'target': path, 'format': 'json', '_salt': str(random)[2:]}
  if start:
    query['from'] = start
  if end:
    query['until'] = end

  url = "http://%s:%d/render/?%s" % (SETTINGS['GRAPHITE_HOST'], SETTINGS['GRAPHITE_PORT'], urlencode(query))
  headers, content = HTTP.request(url, "GET")
  return content

class EnhancedJSONEncoder(DjangoJSONEncoder):
  """
  Custom JSON encoder which can serialize MongoDB's ObjectId objects.
  """
  def default(self, o, **kwargs):
    if isinstance(o, ObjectId):
      return str(o)
    else:
      return DjangoJSONEncoder.default(self, o, **kwargs)

def json(data, status=200):
  data = simplejson.dumps(data, cls=EnhancedJSONEncoder, separators=(',', ':'))
  return HttpResponse(data, mimetype='application/json', status=status)
