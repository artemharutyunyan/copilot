-module(mod_copilot).
-behavior(gen_mod).
-behaviour(gen_server).

-define(JID, "mod_copilot@localhost").

-include("ejabberd.hrl").
-include("jlib.hrl").

% Required by gen_mod
-export([start/2, stop/1, on_presence/4]).
% Required by gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/2]).
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

  ejabberd_hooks:add(set_presence_hook, Host, ?MODULE, on_presence, 50),
  ok.

stop(Host) ->
  ?INFO_MSG("** terminate copilot plugin", []),

  ejabberd_hooks:delete(set_presence_hook, Host, ?MODULE, on_presence),

  Proc = gen_mod:get_module_proc(Host, ?MODULE),
  supervisor:terminate_child(ejabberd_sup, Proc),
  supervisor:delete_child(ejabberd_sup, Proc),

  ok.

on_presence(User, Server, Resource, {xmlelement, "presence", _ , _} = Packet) ->
  {IPAddress, _} = ejabberd_sm:get_user_ip(User, Server, Resource),
  ?INFO_MSG("***Connected user ~p from ~p", [User, IPAddress]),
  gen_server:cast(?MODULE, {userconnect, User, IPAddress}),
  report_event(Server, "connect"),
  ok.

%%% gen_server %%%
start_link(_Host, Opts) ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

init(Args) ->
  application:start(mongodb),
  application:start(egeoip),

  ?DEBUG("mod_copilot_server:init ~p", [Args]),
  %Host = {lists:keyfind(mongodb_host, 1, Args), lists:keyfind(mongodb_port, 1, Data)},
  %{ok, Conn} = mongo:connect(Host),

  State = [{ok, ok}, {mod_opts, Args}],
  {ok, State}.

handle_call(_Request, _From, State) ->
  Reply = ok,
  {reply, Reply, State}.

handle_cast({userconnect, JID, IPAddress}, State) ->
  GeoData = lookup_ip(IPAddress),
  {noreply, State}.

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
% Converts first character to uppercase
ucfirst([]) -> [];
ucfirst([First|Rest]) -> string:to_upper(lists:nth(1, io_lib:format("~c", [First]))) ++ Rest.

lookup_ip(IPAddress) ->
  ?DEBUG("Decoding IP address ~p", [IPAddress]),
  [_|Data] = erlang:tuple_to_list(element(2, egeoip:lookup(IPAddress))),
  lists:zip(egeoip:record_fields(), Data).

% Sends an message as mod_copilot@localhost and
% performs base64-encoding of the attributes
route_to_copilot_component(To, Xml) -> route_to_copilot_component(?JID, To, Xml).
route_to_copilot_component(From, To, Xml) -> ejabberd_router:route(jlib:string_to_jid(From), jlib:string_to_jid(To), hash_xml_body(Xml)).

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

% Sends a reportEvent command to the Monitor
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
