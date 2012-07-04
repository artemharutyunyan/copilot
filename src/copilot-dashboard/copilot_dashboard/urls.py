import os
from django.conf.urls.defaults import patterns, include, url
from local_settings import SETTINGS

docroot = os.path.dirname(os.path.abspath(__file__)) + '/dashboard/static'

urlpatterns = patterns('',
  # API
  url(r'^api/connections/?$', 'copilot_dashboard.dashboard.views.connections', name='connections'),
  url(r'^api/connections/(?P<id>.+)$', 'copilot_dashboard.dashboard.views.connection_info', name='connection_info'),
  url(r'^api/stats', 'copilot_dashboard.dashboard.views.stats', name='stats'),
  url(r'^api/ping', 'copilot_dashboard.dashboard.views.ping', name='ping'),

  # Dashboard/static files
  url(r'^dashboard$', 'django.views.generic.simple.redirect_to', {'url': 'dashboard/'}),
  url(r'^dashboard/$', 'django.views.generic.simple.direct_to_template', {'template': 'index.html',
                                                                          'extra_context': {'api_key': SETTINGS['GMAPS_KEY']}}),
  url(r'^dashboard/(?P<path>.*)$', 'django.views.static.serve', {'document_root': docroot})
)
