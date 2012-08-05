-module(mod_copilot).
-behavior(gen_mod).
-behaviour(gen_server).

-define(JID, "mod_copilot@localhost").
-define(REPORT_INTERVAL, 60000).

-include("ejabberd.hrl").
-include("jlib.hrl").

% Required by gen_mod
-export([start/2, stop/1, on_set_presence/4, on_unset_presence/4]).
% Required by gen_server
-export([start_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
% Utilites
-export([lookup_ip/1, ucfirst/1, report_event/2, report_event/4]).

%%% ejabberd hooks %%%
start(Host, Opts) ->
  ?INFO_MSG("** init copilot plugin", []),

  % Starts the local gen_server under supervision of ejabberd
  Proc = gen_mod:get_module_proc(Host, ?MODULE),
  ExpandedOpts = Opts ++ [{host, Host}],
  ChildSpec = {Proc, {?MODULE, start_link, [Host, ExpandedOpts]},
                     permanent,
                     1000,
                     worker,
                     [?MODULE]},
  supervisor:start_child(ejabberd_sup, ChildSpec),

  % Installs hooks
  ejabberd_hooks:add(set_presence_hook, Host, ?MODULE, on_set_presence, 50),
  ejabberd_hooks:add(unset_presence_hook, Host, ?MODULE, on_unset_presence, 50),

  ok.

stop(Host) ->
  ejabberd_hooks:delete(set_presence_hook, Host, ?MODULE, on_set_presence),
  ejabberd_hooks:delete(unset_presence_hook, Host, ?MODULE, on_unset_presence),

  Proc = gen_mod:get_module_proc(Host, ?MODULE),
  supervisor:terminate_child(ejabberd_sup, Proc),
  supervisor:delete_child(ejabberd_sup, Proc),

  ok.

on_set_presence(User, Host, Resource, _Packet) ->
  {IPAddress, _} = ejabberd_sm:get_user_ip(User, Host, Resource),
  handle_presence(connect, {User, Host, Resource}, IPAddress).
on_unset_presence(User, Host, Resource, _Status) ->
  handle_presence(disconnect, {User, Host, Resource}, null).

%@doc Handles presence stanzas sent by users
handle_presence(UserState, JID, IPAddress) ->
  % Processes the stanza in the gen_server
  gen_server:cast(?MODULE, {UserState, JID, IPAddress}),
  %report_event(Host, atom_to_list(UserState)),
  ok.

%%% gen_server %%%
start_link(_Host, Opts) ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

init(Args) ->
  application:start(egeoip),

  %timer:send_interval(?REPORT_INTERVAL, connected_users_interval),
  Timer = erlang:start_timer(?REPORT_INTERVAL, self(), []),

  State = [{opts, Args},         % Module's settings, as defined in ejabberd.cfg
           {reportTimer, Timer}  % Report timer
          ],
  {ok, State}.

handle_call(_Request, _From, State) ->
  {reply, ok, State}.

%@doc Handles cases when agents connect and disconnect from the server
handle_cast({connect, JID, IPAddress}, State) ->
  Opts = proplists:get_value(opts, State),
  Host = proplists:get_value(host, Opts),
  store_event_details(Host, create_event_details(JID, IPAddress)),
  {noreply, State};
handle_cast({disconnect, {User, _Host, _Resource} = _JID, _IPAddress}, State) ->
  Opts = proplists:get_value(opts, State),
  Host = proplists:get_value(host, Opts),
  AgentData = parse_component_jid(User),
  case proplists:get_value(uuid, AgentData) of
    undefined -> noop;
    UUID -> update_event_details(Host, UUID, {struct, [{"$set", {struct, [
                                                                          {connected, false}
                                                                         ]}
                                                      }]})
  end,
  {noreply, State};
handle_cast(_Msg, State) ->
  {noreply, State}.

%@doc Periodically reports the number of connected users to Co-Pilot monitor
handle_info({timeout, _Ref, _Msg}, State) ->
  Opts = proplists:get_value(opts, State),
  Host = proplists:get_value(host, Opts),
  Sessions = erlang:length(ejabberd_sm:dirty_get_sessions_list()),
  ?DEBUG("Reporting number of connected machines to Co-Pilot Monitor (~p)", [Sessions]),
  report_event(Host, "connected", integer_to_list(Sessions), "value"),
  erlang:start_timer(?REPORT_INTERVAL, self(), []),
  {noreply, State};
handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  application:stop(egeoip),
  ok.

code_change(_OldVsn, State, _Extra) ->
 {ok, State}.

%%% Utilities %%%
%@doc Converts first character to uppercase
ucfirst([]) -> [];
ucfirst([First|Rest]) -> string:to_upper(lists:nth(1, io_lib:format("~c", [First]))) ++ Rest.

%@doc Returns a UNIX timestamp
timestamp() -> timestamp(now()).
timestamp({M, S, _}) -> M*1000000 + S.

%@doc Converts terms into a JSON string
to_json(X) -> lists:flatten(mochijson:encode(X)).

%@doc Returns geosplatial information for given IP
lookup_ip(null) -> [{latitude, 0.0}, {longitude, 0.0}];
lookup_ip(IPAddress) ->
  ?DEBUG("Decoding IP address ~p", [IPAddress]),
  [_|Data] = erlang:tuple_to_list(element(2, egeoip:lookup(IPAddress))),
  lists:zip(egeoip:record_fields(), Data).

%@doc Parses JID (username part) of an agent (ex.: agent_s-10829_1_7_18225d4f-e3f7-4c18-9a18-d6c06992d272_-g). If ID is missing UUID will be used instead.
parse_component_jid(User) ->
  case string:tokens(User, "_") of
    ["agent"|_] = Props ->
      Data = lists:zip([component, id, cpus, rev, uuid, ukn], Props),
      Id = proplists:get_value(id, Data),
      case lists:last(Id) of
          $- ->
      lists:keyreplace(id, 1, Data, {id, Id ++ proplists:get_value(uuid, Data)});
          _Otherwise -> Data
      end;
    [Component|_] -> [{component, Component}]
  end.

%@doc Creates a MonoDB document describing the connection
create_event_details({User, Host, Resource}, IPAddress) ->
  GeoData = lookup_ip(IPAddress),
  Lng = proplists:get_value(longitude, GeoData),
  Lat = proplists:get_value(latitude, GeoData),
  AgentData = parse_component_jid(User),

  {struct, [{user,             User},
            {host,             Host},
            {resource,         Resource},
            {loc,              {array, [Lng, Lat]}},
            {agent_data,       {struct, AgentData}},
            {succeeded_jobs,   0},
            {failed_jobs,      0},
            {contributed_time, 0},
            {connected,        true}]}.

%@doc Sends an message as mod_copilot@localhost and performs base64-encoding of the attributes
route_to_copilot_component(To, Xml) -> route_to_copilot_component(?JID, To, Xml).
route_to_copilot_component(From, To, Xml) -> ejabberd_router:route(jlib:string_to_jid(From), jlib:string_to_jid(To), hash_xml_body(Xml)).

%@doc Parses xmlelements and hashes attributes
hash_xml_body({xmlelement, Tag, Attributes, ChildNodes}) ->
  {xmlelement,
   Tag,
   lists:map(fun hash_xml_attribute/1, Attributes),
   lists:map(fun hash_xml_body/1, ChildNodes)}.

%@doc Performs base64-encoding on tuple's second element
hash_xml_attribute({"id", _} = Attr) -> Attr;
hash_xml_attribute({"to", _} = Attr) -> Attr;
hash_xml_attribute({"from", _} = Attr) -> Attr;
hash_xml_attribute({"noack", _} = Attr) -> Attr;
hash_xml_attribute({Attr, Value}) -> {Attr, "_BASE64:" ++ base64:encode_to_string(Value)}.

%@doc Prepares the reportEvent command
prepare_event_command(Event, Host) -> prepare_event_command(Event, "", Host).
prepare_event_command(Event, Type, Host) -> proplists:delete(Type, prepare_event_command(Event, Type, "", Host)).
prepare_event_command(Event, Type, Value, Host) ->
  [{"command", "reportEvent" ++ ucfirst(Type)},
   {"component", "ejabberd." ++ Host},
   {"event", Event},
   {Type, Value}].

wrap_event_command(To, Command) ->
  {xmlelement, "message", [{"id", erlang:integer_to_list(timestamp())},
                           {"from", ?JID},
                           {"to", To},
                           {"noack", "1"}],
                          [{xmlelement, "body", [], [
                                                      {xmlelement, "info", Command, []}
                                                    ]}
                          ]}.

%@doc Sends a reportEvent command to the Monitor
report_event(Host, Event) ->
  To = gen_mod:get_module_opt(Host, ?MODULE, monitor_jid, "monitor@localhost"),
  XmlBody = wrap_event_command(To, prepare_event_command(Event, Host)),
  route_to_copilot_component(To, XmlBody),
  ok.

%@doc Sends a reportEvent{Type} command to the Monitor
report_event(Host, Event, Value, Type) ->
  To = gen_mod:get_module_opt(Host, ?MODULE, monitor_jid, "monitor@localhost"),
  XmlBody = wrap_event_command(To, prepare_event_command(Event, Type, Value, Host)),
  route_to_copilot_component(To, XmlBody),
  ok.

store_event_details(Host, Details) ->
  To = gen_mod:get_module_opt(Host, ?MODULE, monitor_jid, "monitor@localhost"),
  XmlBody = wrap_event_command(To, [{"command", "storeEventDetails"},
                                    {"details", to_json(Details)}]),
  route_to_copilot_component(To, XmlBody),
  ok.

update_event_details(Host, Session, Updates) ->
  To = gen_mod:get_module_opt(Host, ?MODULE, monitor_jid, "monitor@localhost"),
  XmlBody = wrap_event_command(To, [{"command", "updateEventDetails"},
                                    {"session", Session},
                                    {"updates", to_json(Updates)}]),
  route_to_copilot_component(To, XmlBody),
  ok.
