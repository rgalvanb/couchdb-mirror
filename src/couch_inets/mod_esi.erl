%% ``The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved via the world wide web at http://www.erlang.org/.
%% 
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%% 
%% The Initial Developer of the Original Code is Ericsson Utvecklings AB.
%% Portions created by Ericsson are Copyright 1999, Ericsson Utvecklings
%% AB. All Rights Reserved.''
%% 
%%     $Id$
%%
-module(mod_esi).

%% API
%% Functions provided to help erl scheme alias programmer to 
%% Create dynamic webpages that are sent back to the user during 
%% Generation
-export([deliver/2]).

%% Callback API
-export([do/1, load/2]).

-include("httpd.hrl").

-define(VMODULE,"ESI").
-define(DEFAULT_ERL_TIMEOUT,15000).

%%%=========================================================================
%%%  API 
%%%=========================================================================
%%--------------------------------------------------------------------------
%% deliver(SessionID, Data) -> ok | {error, bad_sessionID}
%%	SessionID = pid()
%%	Data = string() | io_list() (first call must send a string that 
%%	contains all header information including "\r\n\r\n", unless there
%%	is no header information at all.)
%%
%% Description: Send <Data> (Html page generated sofar) to the server
%% request handling process so it can forward it to the client.
%%-------------------------------------------------------------------------
deliver(SessionID, Data) when pid(SessionID) ->
    SessionID ! {ok, Data},
    ok;
deliver(_SessionID, _Data) ->
    {error, bad_sessionID}.

%%%=========================================================================
%%%  CALLBACK API 
%%%=========================================================================
%%--------------------------------------------------------------------------
%% do(ModData) -> {proceed, OldData} | {proceed, NewData} | {break, NewData} 
%%                | done
%%     ModData = #mod{}
%%
%% Description:  See httpd(3) ESWAPI CALLBACK FUNCTIONS
%%-------------------------------------------------------------------------
do(ModData) ->
    case httpd_util:key1search(ModData#mod.data, status) of
	{_StatusCode, _PhraseArgs, _Reason} ->
	    {proceed, ModData#mod.data};
	undefined ->
	    case httpd_util:key1search(ModData#mod.data, response) of
		undefined ->
		    generate_response(ModData);
		_Response ->
		    {proceed, ModData#mod.data}
	    end
    end.
%%--------------------------------------------------------------------------
%% load(Line, Context) ->  eof | ok | {ok, NewContext} | 
%%                     {ok, NewContext, Directive} | 
%%                     {ok, NewContext, DirectiveList} | {error, Reason}
%% Line = string()
%% Context = NewContext = DirectiveList = [Directive]
%% Directive = {DirectiveKey , DirectiveValue}
%% DirectiveKey = DirectiveValue = term()
%% Reason = term() 
%%
%% Description: See httpd(3) ESWAPI CALLBACK FUNCTIONS
%%-------------------------------------------------------------------------
load("ErlScriptAlias " ++ ErlScriptAlias, []) ->
    case regexp:split(ErlScriptAlias," ") of
	{ok, [ErlName | Modules]} ->
	    {ok, [], {erl_script_alias, {ErlName,Modules}}};
	{ok, _} ->
	    {error, ?NICE(httpd_conf:clean(ErlScriptAlias) ++
			 " is an invalid ErlScriptAlias")}
    end;
load("EvalScriptAlias " ++ EvalScriptAlias, []) ->
    case regexp:split(EvalScriptAlias, " ") of
	{ok, [EvalName|Modules]} ->
	    {ok, [], {eval_script_alias, {EvalName, Modules}}};
	{ok, _} ->
	    {error, ?NICE(httpd_conf:clean(EvalScriptAlias) ++
			  " is an invalid EvalScriptAlias")}
    end;
load("ErlScriptTimeout " ++ Timeout, [])->
    case catch list_to_integer(httpd_conf:clean(Timeout)) of
	TimeoutSec when integer(TimeoutSec)  ->
	   {ok, [], {erl_script_timeout, TimeoutSec * 1000}};
	_ ->
	   {error, ?NICE(httpd_conf:clean(Timeout) ++
			 " is an invalid ErlScriptTimeout")}
    end;
load("ErlScriptNoCache " ++ CacheArg, [])->
    case catch list_to_atom(httpd_conf:clean(CacheArg)) of
        true ->
	    {ok, [], {erl_script_nocache, true}};
	false ->
	   {ok, [], {erl_script_nocache, false}};
	_ ->
	   {error, ?NICE(httpd_conf:clean(CacheArg)++
			 " is an invalid ErlScriptNoCache directive")}
    end.

%%%========================================================================
%%% Internal functions
%%%========================================================================   
generate_response(ModData) ->
    case scheme(ModData#mod.request_uri, ModData#mod.config_db) of
	{eval, ESIBody, Modules} ->
	    eval(ModData, ESIBody, Modules);
	{erl, ESIBody, Modules} ->
	    erl(ModData, ESIBody, Modules);
	no_scheme ->
	    {proceed, ModData#mod.data}
    end.

scheme(RequestURI, ConfigDB) ->
    case match_script(RequestURI, ConfigDB, erl_script_alias) of
	no_match ->
	    case match_script(RequestURI, ConfigDB, eval_script_alias) of
		no_match ->
		    no_scheme;
		{EsiBody, ScriptModules} ->
		    {eval, EsiBody, ScriptModules}
	    end;
	{EsiBody, ScriptModules} ->
	    {erl, EsiBody, ScriptModules}
    end.

match_script(RequestURI, ConfigDB, AliasType) ->
    case httpd_util:multi_lookup(ConfigDB, AliasType) of
	[] ->
	    no_match;
	AliasAndMods ->
	    match_esi_script(RequestURI, AliasAndMods, AliasType)
    end.

match_esi_script(_, [], _) ->
    no_match;
match_esi_script(RequestURI, [{Alias,Modules} | Rest], AliasType) ->
    AliasMatchStr = alias_match_str(Alias, AliasType),
    case regexp:first_match(RequestURI, AliasMatchStr) of
	{match, 1, Length} ->
	    {string:substr(RequestURI, Length + 1), Modules};
	nomatch ->
	    match_esi_script(RequestURI, Rest, AliasType)
    end.

alias_match_str(Alias, erl_script_alias) ->
    "^" ++ Alias ++ "/";
alias_match_str(Alias, eval_script_alias) ->
    "^" ++ Alias ++ "\\?".


%%------------------------ Erl mechanism --------------------------------

erl(#mod{method = Method} = ModData, ESIBody, Modules) 
  when Method == "GET"; Method == "HEAD"->
    case httpd_util:split(ESIBody,":|%3A|/",2) of
	{ok, [Module, FuncAndInput]} ->
	    case httpd_util:split(FuncAndInput,"[\?/]",2) of
		{ok, [FunctionName, Input]} ->
		    generate_webpage(ModData, ESIBody, Modules, 
				     Module, FunctionName, Input, 
				    script_elements(FunctionName, Input));
		{ok, [FunctionName]} ->
		    generate_webpage(ModData, ESIBody, Modules, 
				     Module, FunctionName, "", 
				     script_elements(FunctionName, ""));
		{ok, BadRequest} ->
		    {proceed,[{status,{400,none, BadRequest}} | 
			      ModData#mod.data]}
	    end;
	{ok, BadRequest} ->
	    {proceed, [{status,{400, none, BadRequest}} | ModData#mod.data]}
    end;

erl(#mod{method = "POST", entity_body = Body} = ModData, ESIBody, Modules) ->
    case httpd_util:split(ESIBody,":|%3A|/",2) of
	{ok,[Module, Function]} ->
	    generate_webpage(ModData, ESIBody, Modules, Module, 
			     Function, Body, [{entity_body, Body}]);
	{ok, BadRequest} ->
	    {proceed,[{status, {400, none, BadRequest}} | ModData#mod.data]}
    end.

generate_webpage(ModData, ESIBody, ["all"], ModuleName, FunctionName,
		 Input, ScriptElements) ->
    generate_webpage(ModData, ESIBody, [ModuleName], ModuleName,
		     FunctionName, Input, ScriptElements);
generate_webpage(ModData, ESIBody, Modules, ModuleName, FunctionName,
		 Input, ScriptElements) ->
    case lists:member(ModuleName, Modules) of
	true ->
	    Env = httpd_script_env:create_env(esi, ModData, ScriptElements),
	    Module = list_to_atom(ModuleName),
	    Function = list_to_atom(FunctionName),
	    case erl_scheme_webpage_chunk(Module, Function, 
					  Env, Input, ModData) of
		{error, erl_scheme_webpage_chunk_undefined} ->
		    erl_scheme_webpage_whole(Module, Function, Env, Input,
					     ModData);
		ResponseResult ->
		    ResponseResult
	    end;
	false ->
	    {proceed, [{status, {403, ModData#mod.request_uri,
				 ?NICE("Client not authorized to evaluate: "
				       ++  ESIBody)}} | ModData#mod.data]}
    end.

%% Old API that waits for the dymnamic webpage to be totally generated
%% before anythig is sent back to the client.
erl_scheme_webpage_whole(Module, Function, Env, Input, ModData) ->
    case (catch Module:Function(Env, Input)) of
	{'EXIT',Reason} ->
	    {proceed, [{status, {500, none, Reason}} |
		       ModData#mod.data]};
	Response ->
	    {Headers, Body} = 
		httpd_esi:parse_headers(lists:flatten(Response)),
	    Length =  httpd_util:flatlength(Body),
	    case httpd_esi:handle_headers(Headers) of
		{proceed, AbsPath} ->
		    {proceed, [{real_name, httpd_util:split_path(AbsPath)} 
			       | ModData#mod.data]};
		{ok, NewHeaders, StatusCode} ->
		    send_headers(ModData, StatusCode, 
				 [{"content-length", 
				   integer_to_list(Length)}| NewHeaders]),
		    case ModData#mod.method of
			"HEAD" ->
			    {proceed, [{response, {already_sent, 200, 0}} | 
				       ModData#mod.data]};
			_ ->
			    httpd_response:send_body(ModData, 
						     StatusCode, Body),
			    {proceed, [{response, {already_sent, 200, 
						  Length}} | 
				       ModData#mod.data]}
		    end
	    end
    end.

%% New API that allows the dynamic wepage to be sent back to the client 
%% in small chunks at the time during generation.
erl_scheme_webpage_chunk(Mod, Func, Env, Input, ModData) -> 
    process_flag(trap_exit, true),
    Self = self(),
    %% Spawn worker that generates the webpage.
    %% It would be nicer to use erlang:function_exported/3 but if the 
    %% Module isn't loaded the function says that it is not loaded
    Pid = spawn_link(
	    fun() ->
		    case catch Mod:Func(Self, Env, Input) of
			{'EXIT',{undef,_}} ->
			    %% Will force fallback on the old API
			    exit(erl_scheme_webpage_chunk_undefined);
			_ ->
			    ok  
		    end
	    end),
 
    Response = deliver_webpage_chunk(ModData, Pid), 
  
    process_flag(trap_exit,false),
    Response.

deliver_webpage_chunk(#mod{config_db = Db} = ModData, Pid) ->
    Timeout = erl_script_timeout(Db),
    deliver_webpage_chunk(ModData, Pid, Timeout).

deliver_webpage_chunk(#mod{config_db = Db} = ModData, Pid, Timeout) ->
    case receive_headers(Timeout) of
	{error, Reason} ->
	    %% Happens when webpage generator callback/3 is undefined
	    {error, Reason}; 
	{Headers, Body} ->
	    case httpd_esi:handle_headers(Headers) of
		{proceed, AbsPath} ->
		    {proceed, [{real_name, httpd_util:split_path(AbsPath)} 
			       | ModData#mod.data]};
		{ok, NewHeaders, StatusCode} ->
		    IsDisableChunkedSend = 
			httpd_response:is_disable_chunked_send(Db),
		    case (ModData#mod.http_version =/= "HTTP/1.1") or
			(IsDisableChunkedSend) of
			true ->
			    send_headers(ModData, StatusCode, 
					 [{"connection", "close"} | 
					  NewHeaders]);
			false ->
			    send_headers(ModData, StatusCode, 
					 [{"transfer-encoding", 
					   "chunked"} | NewHeaders])
		    end,    
		    handle_body(Pid, ModData, Body, Timeout, length(Body), 
				IsDisableChunkedSend)
	    end;
	timeout ->
	    send_headers(ModData, {504, "Timeout"},[{"connection", "close"}]),
	    httpd_socket:close(ModData#mod.socket_type, ModData#mod.socket),
	    process_flag(trap_exit,false),
	    {proceed,[{response, {already_sent, 200, 0}} | ModData#mod.data]}
    end.

receive_headers(Timeout) ->
    receive
	{ok, Chunk} ->
	    httpd_esi:parse_headers(lists:flatten(Chunk));		
	{'EXIT', Pid, erl_scheme_webpage_chunk_undefined} when is_pid(Pid) ->
	    {error, erl_scheme_webpage_chunk_undefined};
	{'EXIT', Pid, Reason} when is_pid(Pid) ->
	    exit({mod_esi_linked_process_died, Pid, Reason})
    after Timeout ->
	    timeout
    end.

send_headers(ModData, StatusCode, HTTPHeaders) ->
    ExtraHeaders = httpd_response:cache_headers(ModData),
    httpd_response:send_header(ModData, StatusCode, 
			       ExtraHeaders ++ HTTPHeaders).

handle_body(_, #mod{method = "HEAD"} = ModData, _, _, Size, _) ->
    process_flag(trap_exit,false),
    {proceed, [{response, {already_sent, 200, Size}} | ModData#mod.data]};

handle_body(Pid, ModData, Body, Timeout, Size, IsDisableChunkedSend) ->
    httpd_response:send_chunk(ModData, Body, IsDisableChunkedSend),
    receive 
	{ok, Data} ->
	    handle_body(Pid, ModData, Data, Timeout, Size + length(Data),
			IsDisableChunkedSend);
	{'EXIT', Pid, normal} when is_pid(Pid) ->
	    httpd_response:send_final_chunk(ModData, IsDisableChunkedSend),
	    {proceed, [{response, {already_sent, 200, Size}} | 
		       ModData#mod.data]};
	{'EXIT', Pid, Reason} when is_pid(Pid) ->
	    exit({mod_esi_linked_process_died, Pid, Reason})
    after Timeout ->
	    process_flag(trap_exit,false),
	    {proceed,[{response, {already_sent, 200, Size}} | 
		      ModData#mod.data]}  
    end.

erl_script_timeout(Db) ->
    httpd_util:lookup(Db, erl_script_timeout, ?DEFAULT_ERL_TIMEOUT).

script_elements(FuncAndInput, Input) ->
    case input_type(FuncAndInput) of
        path_info ->
	    [{path_info, Input}];
	query_string ->
	    [{query_string, Input}];
	_ ->
	    []
    end.

input_type([]) ->
    no_input;
input_type([$/|_Rest]) ->
    path_info;
input_type([$?|_Rest]) ->
    query_string;
input_type([_First|Rest]) ->
    input_type(Rest).

%%------------------------ Eval mechanism --------------------------------

eval(#mod{request_uri = ReqUri, method = "POST",
	  http_version = Version, data = Data}, _ESIBody, _Modules) ->
    {proceed,[{status,{501,{"POST", ReqUri, Version},
		       ?NICE("Eval mechanism doesn't support method POST")}}|
	      Data]};

eval(#mod{method = Method} = ModData, ESIBody, Modules) 
  when Method == "GET"; Method == "HEAD" ->
    case is_authorized(ESIBody, Modules) of
	true ->
	    case generate_webpage(ESIBody) of
		{error, Reason} ->
		    {proceed, [{status, {500, none, Reason}} | 
			       ModData#mod.data]};
		{ok, Response} ->
		    {Headers, _} = 
			httpd_esi:parse_headers(lists:flatten(Response)),
		    case httpd_esi:handle_headers(Headers) of
			{ok, _, StatusCode} ->
			    {proceed,[{response, {StatusCode, Response}} | 
				      ModData#mod.data]};
			{proceed, AbsPath} ->
			    {proceed, [{real_name, AbsPath} | 
				       ModData#mod.data]}
		    end
	    end;
	false ->
	    {proceed,[{status,
		       {403, ModData#mod.request_uri,
			?NICE("Client not authorized to evaluate: "
			      ++ ESIBody)}} | ModData#mod.data]}
    end.

generate_webpage(ESIBody) ->
    (catch lib:eval_str(string:concat(ESIBody,". "))).

is_authorized(_ESIBody, ["all"]) ->
    true;
is_authorized(ESIBody, Modules) ->
    case regexp:match(ESIBody, "^[^\:(%3A)]*") of
	{match, Start, Length} ->
	    lists:member(string:substr(ESIBody, Start, Length), Modules);
	nomatch ->
	    false
    end.
