-module(mod_copilot).
-behavior(gen_mod).
-define(PROCNAME, mod_copilot).
-define(JID, "mod_copilot@localhost").

-include("ejabberd.hrl").
-include("jlib.hrl").
-export([start/2, stop/1, on_presence/4, lookup_ip/1, ucfirst/1, report_event/2, report_event/4]).

start(Host, _Opt) ->
  ?INFO_MSG("** init copilot plugin", []),

  application:start(mongodb),
  application:start(egeoip),

  ejabberd_hooks:add(set_presence_hook, Host, ?MODULE, on_presence, 50),
  ok.

stop(Host) ->
  ?INFO_MSG("** terminate copilot plugin", []),

  ejabberd_hooks:delete(set_presence_hook, Host, ?MODULE, on_presence),

  application:stop(mongodb),
  application:stop(),

  ok.

on_presence(User, Server, Resource, _Packet) ->
  IPAddress = ejabberd_sm:get_user_ip(User, Server, Resource),
  Data = lookup_ip(IPAddress),
  ?DEBUG("User with the IP address ~p sent a presence from (~p, ~p)", [IPAddress,
                                                                       lists:keyfind(latitude, 1, Data),
                                                                       lists:keyfind(longitude, 1, Data)]),
  report_event(Server, "connect"),
  ok.

%%% Utilities %%%
% Converts first character to uppercase
ucfirst([]) -> [];
ucfirst([First|Rest]) -> string:to_upper(lists:nth(1, io_lib:format("~c", [First]))) ++ Rest.

lookup_ip(IPAddress) ->
  {ok, Values} = egeoip:lookup(IPAddress),
  [_|Data] = erlang:tuple_to_list(Values),
  lists:zip(egeoip:record_fields(), Data).

% Sends an message as mod_copilot@localhost and
% performs base64-encoding of the attributes
route_to_copilot_component(To, Xml) ->
  ejabberd_router:route(?JID, To, Xml).

route_to_copilot_component(From, To, Xml) ->
  ejabberd_router:route(From, To, hash_xml_body(Xml)).

hash_xml_body({xmlelement, Tag, Attributes, ChildNodes}) ->
  {xmlelement,
   Tag,
   lists:map(fun hash_xml_attribute/1, Attributes),
   lists:map(fun hash_xml_body/1, ChildNodes)}.

% Performs base64-encoding on tuple's second element
hash_xml_attribute({"to", _} = Attr) -> Attr;
hash_xml_attribute({"from", _} = Attr) -> Attr;
hash_xml_attribute({Attr, Value}) -> {Attr, "_BASE64:" ++  base64:encode_to_string(Value)}.

% Prepares the reportEvent command
prepare_event_command(Event) -> prepare_event_command(Event, "").
prepare_event_command(Event, Type) -> lists:keydelete(Type, 1, prepare_event_command(Event, Type, "")).
prepare_event_command(Event, Type, Value) ->
  [{"command", "reportEvent" ++ ucfirst(Type)},
   {"component", "copilot.ejabberd"},
   {"event", Event},
   {Type, Value}].

report_event(Server, Event) ->
  To = gen_mod:get_module_opt(Server, ?MODULE, monitor_jid, "mon@localhost"),
  XmlBody = {xmlelement, "message", [{"from", ?JID},
                                     {"to", To},
                                     {"noack", "1"}],
                                     [{xmlelement, "info", prepare_event_command(Event), []}]},
  route_to_copilot_component(To, XmlBody),
  ok.
report_event(Server, Event, Value, Type) ->
  To = gen_mod:get_module_opt(Server, ?MODULE, monitor_jid, "mon@localhost"),
  XmlBody = {xmlelement, "message", [{"from", ?JID},
                                     {"to", To},
                                     {"noack", "1"},
                                    [{xmlelement, "info", prepare_event_command(Event, Value, Type), []}]]},
  route_to_copilot_component(To, XmlBody),
  ok.
