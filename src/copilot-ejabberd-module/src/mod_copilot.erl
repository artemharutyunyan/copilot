-module(mod_copilot).
-behavior(gen_mod).
-behaviour(gen_server).

-define(JID, "mod_copilot@localhost").

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
  ChildSpec = {Proc, {?MODULE, start_link, [Host, Opts]},
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

on_set_presence(User, Server, Resource, _Packet) ->   handle_presence(connect, {User, Server, Resource}).
on_unset_presence(User, Server, Resource, _Status) -> handle_presence(disconnect, {User, Server, Resource}).

%@doc Handles presence stanzas sent by users
handle_presence(UserState, {User, Server, Resource} = JID) ->
  {IPAddress, _} = ejabberd:get_user_ip(User, Server, Resource),
  ?DEBUG("User ~p (~p) is ~p", [JID, IPAddress, UserState]),

  % Passes over the processing into a new process
  gen_server:cast(?MODULE, {UserState, JID, IPAddress}),
  report_event(Server, UserState),
  ok.

%%% gen_server %%%
start_link(_Host, Opts) ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

init(Args) ->
  application:start(mongodb),
  application:start(egeoip),

  Host = case proplists:get_value(mongodb, Args) of
    undefined -> {localhost, 27017};
    Value -> Value
  end,
  {ok, Conn} = mongo:connect(Host),

  State = [{opts, Args},   % Module's settings, as defined in the ejabberd.cfg
           {mongo, Conn}   % MongoDB connection
          ],
  {ok, State}.

handle_call(_Request, _From, State) ->
  Reply = ok,
  {reply, Reply, State}.

%@doc Handles cases when agents connect and disconnect from the server
handle_cast({connect, JID, IPAddress}, State) ->
  Doc = doc_create_connection(JID, IPAddress),
  mongo_do(State, copilot, fun () -> mongo:save(connections, Doc) end);
handle_cast({disconnect, {User, Host, Resource} = JID, IPAddress}, State) ->
  mongo_do(State, copilot, fun () ->
    JIDString = User ++ "@" ++ Host ++ "/" ++ Resource,
    Cursor = mongo:find(connections, {jid, JIDString,
                                      active, true}),
    NewDoc = doc_close_connection(mongo:next(Cursor), JID, IPAddress),
    mongo:close_cursor(Cursor),
    mongo:save(connections, NewDoc)
  end);
handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  application:stop(mongodb),
  application:stop(egeoip),
  ok.

code_change(_OldVsn, State, _Extra) ->
 {ok, State}.

%%% Utilities %%%
%@doc Converts first character to uppercase
ucfirst([]) -> [];
ucfirst([First|Rest]) -> string:to_upper(lists:nth(1, io_lib:format("~c", [First]))) ++ Rest.

%@doc Mongo driver invalidates the connection on every error,
mongo_reconnect(State) ->
  mongo:disconnect(proplists:get_value(mongo, State)),
  Opts = proplists:get_value(opts, State),
  Host = case proplists:get_value(mongodb, Opts) of
    undefined -> {localhost, 27017};
    Value -> Value
  end,
  {ok, NewConn} = mongo:connect(Host),
  proplists:delete(conn, State) ++ [{conn, NewConn}].

%@doc Wrapper around mongo:do/5 which is too error-sensitive
mongo_do(State, Table, Op) ->
  Conn = proplists:get_value(mongo, State),
  case mongo:do(safe, master, Conn, Table, Op) of
    {ok, _} -> {noreply, State};
    {failure, Failure} ->
      ?DEBUG("MongoDB operation failed with: ~p", [Failure]),
      {noreply, mongo_reconnect(State)}
  end.

%@doc Returns geosplatial information for given IP
lookup_ip(IPAddress) ->
  ?DEBUG("Decoding IP address ~p", [IPAddress]),
  [_|Data] = erlang:tuple_to_list(element(2, egeoip:lookup(IPAddress))),
  lists:zip(egeoip:record_fields(), Data).

%@doc Parses JID (username part) of an agent (ex.: agent_s-10829_1_7_18225d4f-e3f7-4c18-9a18-d6c06992d272_-g)
parse_component_jid(User) ->
  lists:zip([component, version, cores, jobs, uuid, ukn], strings:tokens(User, "_")).

%@doc Creates a MonoDB document describing the connection
doc_create_connection({User, Host, Resource}, IPAddress) ->
  GeoData = lookup_ip(IPAddress),
  Lng = proplists:get_value(longitude, GeoData),
  Lat = proplists:get_value(latitude, GeoData),

  {jid, User ++ "@" ++ Host ++ "/" ++ Resource,
   loc, [Lng, Lat],
   connected_at, bson:timenow(),
   connected, true}.

%@doc Marks connection as closed and appends data from agent's JID
doc_close_connection({ok, {}}, JID, IPAddress) ->
  % There isn't a connection document so we have to create it first
  doc_close_connection(doc_create_connection(JID, IPAddress));
doc_close_connection({ok, {Doc}}, {User, _Host, _Resource} = JID, IPAddress) ->
  % Converts a list of tuples ([{x, Y}]) into a list of lists ([[x, Y]]) and flattens it ([x, Y]) for BSON
  AgentData = erlang:list_to_tuple(list:flatmap(fun erlang:tuple_to_list/1, parse_component_jid(User))),
  NewData = {disconnected_at, bson:timenow(),
             agent_data, AgentData},
  bson:append(bson:update(connected, false, Doc), NewData);
doc_close_connection({failure, Failure}, _, _) ->
  % Silently fails
  ?DEBUG("MongoDB failed in doc_close_connection ~p", [Failure]),
  failure.

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
hash_xml_attribute({"to", _} = Attr) -> Attr;
hash_xml_attribute({"from", _} = Attr) -> Attr;
hash_xml_attribute({"noack", _} = Attr) -> Attr;
hash_xml_attribute({Attr, Value}) -> {Attr, "_BASE64:" ++  base64:encode_to_string(Value)}.

%@doc Prepares the reportEvent command
prepare_event_command(Event) -> prepare_event_command(Event, "").
prepare_event_command(Event, Type) -> lists:keydelete(Type, 1, prepare_event_command(Event, Type, "")).
prepare_event_command(Event, Type, Value) ->
  [{"command", "reportEvent" ++ ucfirst(Type)},
   {"component", "copilot.ejabberd"},
   {"event", Event},
   {Type, Value}].

%@doc Sends a reportEvent command to the Monitor
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
