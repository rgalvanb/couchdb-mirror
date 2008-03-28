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

-module(httpd_request).

-include("http_internal.hrl").
-include("httpd.hrl").

-export([parse/1, whole_body/2, validate/3, update_mod_data/5,
	 body_data/2]).

%% Callback API - used for example if the header/body is received a
%% little at a time on a socket. 
-export([parse_method/1, parse_uri/1, parse_version/1, parse_headers/1,
	 whole_body/1]).

%%%=========================================================================
%%%  Internal application API
%%%=========================================================================
parse([Bin, MaxHeaderSize]) ->
         parse_method(Bin, [], MaxHeaderSize, []).

%% Functions that may be returned during the decoding process
%% if the input data is incompleate. 
parse_method([Bin, Method, MaxHeaderSize, Result]) ->
    parse_method(Bin, Method, MaxHeaderSize, Result).

parse_uri([Bin, URI, MaxHeaderSize, Result]) ->
    parse_uri(Bin, URI, MaxHeaderSize, Result).

parse_version([Bin, Rest, Version, MaxHeaderSize, Result]) ->
    parse_version(<<Rest/binary, Bin/binary>>, Version, MaxHeaderSize, 
		  Result).

parse_headers([Bin, Rest, Header, Headers, MaxHeaderSize, Result]) ->
    parse_headers(<<Rest/binary, Bin/binary>>, 
		  Header, Headers, MaxHeaderSize, Result).

whole_body([Bin, Body, Length])  ->
    whole_body(<<Body/binary, Bin/binary>>, Length).    


%% Separate the body for this request from a possible piplined new 
%% request and convert the body data to "string" format.
body_data(Headers, Body) ->    
    ContentLength = list_to_integer(Headers#http_request_h.'content-length'),
    case size(Body) - ContentLength of
 	0 ->
 	    {binary_to_list(Body), <<>>};
 	_ ->
 	    <<BodyThisReq:ContentLength/binary, Next/binary>> = Body,   
 	    {binary_to_list(BodyThisReq), Next}
    end.

%%-------------------------------------------------------------------------
%% validate(Method, Uri, Version) -> ok | {error, {bad_request, Reason} |
%%			     {error, {not_supported, {Method, Uri, Version}}
%%      Method = "HEAD" | "GET" | "POST" | "TRACE"
%%      Uri = uri()
%%      Version = "HTTP/N.M"      
%% Description: Checks that HTTP-request-line is valid.
%%------------------------------------------------------------------------- 
validate("HEAD", Uri, "HTTP/1." ++ _N) ->
    validate_uri(Uri);
validate("GET", Uri, []) -> %% Simple HTTP/0.9 
    validate_uri(Uri);
validate("GET", Uri, "HTTP/0.9") ->
    validate_uri(Uri);
validate("GET", Uri, "HTTP/1." ++ _N) ->
    validate_uri(Uri);
validate("POST", Uri, "HTTP/1." ++ _N) ->
    validate_uri(Uri);
validate("TRACE", Uri, "HTTP/1." ++ N) when hd(N) >= $1 ->
    validate_uri(Uri);
validate("PUT", Uri, "HTTP/1." ++ _N) ->
    validate_uri(Uri);
validate("DELETE", Uri, "HTTP/1." ++ _N) ->
    validate_uri(Uri);
validate(Method, Uri, Version) ->
    {error, {not_supported, {Method, Uri, Version}}}.

%%----------------------------------------------------------------------
%% The request is passed through the server as a record of type mod 
%% create it.
%% ----------------------------------------------------------------------
update_mod_data(ModData, Method, RequestURI, HTTPVersion, Headers)-> 
    ParsedHeaders =  tagup_header(Headers),
    PersistentConn = get_persistens(HTTPVersion, ParsedHeaders, 
				    ModData#mod.config_db),
    {ok, ModData#mod{data = [],
		     method = Method,
		     absolute_uri = format_absolute_uri(RequestURI, 
							ParsedHeaders),
		     request_uri = format_request_uri(RequestURI),
		     http_version = HTTPVersion,
		     request_line = Method ++ " " ++ RequestURI ++ 
		     " " ++ HTTPVersion,
		     parsed_header = ParsedHeaders,
		     connection = PersistentConn}}.

%%%========================================================================
%%% Internal functions
%%%========================================================================
parse_method(<<>>, Method, MaxHeaderSize, Result) ->
    {?MODULE, parse_method, [Method, MaxHeaderSize, Result]};
parse_method(<<?SP, Rest/binary>>, Method, MaxHeaderSize, Result) ->
    parse_uri(Rest, [], MaxHeaderSize,
	      [string:strip(lists:reverse(Method)) | Result]);
parse_method(<<Octet, Rest/binary>>, Method, MaxHeaderSize, Result) ->
    parse_method(Rest, [Octet | Method], MaxHeaderSize, Result).

parse_uri(<<>>, URI, MaxHeaderSize, Result) ->
    {?MODULE, parse_uri, [URI, MaxHeaderSize, Result]};
parse_uri(<<?SP, Rest/binary>>, URI, MaxHeaderSize, Result) -> 
    parse_version(Rest, [], MaxHeaderSize, 
		  [string:strip(lists:reverse(URI)) | Result]);
%% Can happen if it is a simple HTTP/0.9 request e.i "GET /\r\n\r\n"
parse_uri(<<?CR, _Rest/binary>> = Data, URI, MaxHeaderSize, Result) -> 
    parse_version(Data, [], MaxHeaderSize, 
		  [string:strip(lists:reverse(URI)) | Result]);
parse_uri(<<Octet, Rest/binary>>, URI, MaxHeaderSize, Result) ->
    parse_uri(Rest, [Octet | URI], MaxHeaderSize, Result).

parse_version(<<>>, Version, MaxHeaderSize, Result) ->
    {?MODULE, parse_version, [<<>>, Version, MaxHeaderSize, Result]};
parse_version(<<?CR, ?LF, Rest/binary>>, Version, MaxHeaderSize, Result) ->
    parse_headers(Rest, [], [], MaxHeaderSize, 
		  [string:strip(lists:reverse(Version)) | Result]);
parse_version(<<?CR>> = Data, Version, MaxHeaderSize, Result) ->
    {?MODULE, parse_version, [Data, Version, MaxHeaderSize, Result]};
parse_version(<<Octet, Rest/binary>>, Version, MaxHeaderSize, Result) ->
    parse_version(Rest, [Octet | Version], MaxHeaderSize, Result).

parse_headers(<<>>, Header, Headers, MaxHeaderSize, Result) ->
    {?MODULE, parse_headers, [<<>>, Header, Headers, MaxHeaderSize, Result]};
parse_headers(<<?CR,?LF,?CR,?LF,Body/binary>>, [], [], _, Result) ->
     NewResult = list_to_tuple(lists:reverse([Body, {#http_request_h{}, []} |
					      Result])),
    {ok, NewResult};
parse_headers(<<?CR,?LF,?CR,?LF,Body/binary>>, Header, Headers,
	      MaxHeaderSize, Result) ->
    HTTPHeaders = [lists:reverse(Header) | Headers],
    Length =   lists:foldl(fun(H, Acc) -> length(H) + Acc end,
			   0, HTTPHeaders),
    case ((Length > MaxHeaderSize) or (MaxHeaderSize == nolimit)) of
	true ->
	    {error, {header_too_long, MaxHeaderSize}, 
	     lists:nth(3, lists:reverse(Result))}; % HTTP Version
	false ->
	    RequestHeaderRcord = 
		http_request:headers(HTTPHeaders, #http_request_h{}),
	    NewResult = 
		list_to_tuple(lists:reverse([Body, {RequestHeaderRcord, 
						    HTTPHeaders} | Result])),
	    {ok, NewResult}
    end;
parse_headers(<<?CR,?LF,?CR>> = Data, Header, Headers, 
	      MaxHeaderSize, Result) ->
    {?MODULE, parse_headers, [Data, Header, Headers, MaxHeaderSize, Result]};

%% There where no headers, which is unlikely to happen.
parse_headers(<<?CR,?LF>>, [], [], _, Result) ->
     NewResult = list_to_tuple(lists:reverse([<<>>, {#http_request_h{}, []} |
					      Result])),
    {ok, NewResult};
parse_headers(<<?CR,?LF>> = Data, Header, Headers, 
	      MaxHeaderSize, Result) ->
    {?MODULE, parse_headers, [Data, Header, Headers, MaxHeaderSize, Result]};
parse_headers(<<?CR,?LF, Octet, Rest/binary>>, Header, Headers, 
	      MaxHeaderSize, Result) ->
    parse_headers(Rest, [Octet], [lists:reverse(Header) | Headers], 
		  MaxHeaderSize, Result);
parse_headers(<<?CR>> = Data, Header, Headers, 
	      MaxHeaderSize, Result) ->
    {?MODULE, parse_headers, [Data, Header, Headers, MaxHeaderSize, Result]};
parse_headers(<<Octet, Rest/binary>>, Header, Headers, 
	      MaxHeaderSize, Result) ->
    parse_headers(Rest, [Octet | Header], Headers, MaxHeaderSize, Result).

whole_body(Body, Length) ->
    case size(Body) of
	N when N < Length, Length > 0 ->
	  {?MODULE, whole_body, [Body, Length]};
	N when N >= Length, Length >= 0 ->  
	    %% When a client uses pipelining trailing data
	    %% may be part of the next request!
	    %% Trailing data will be separated from 
	    %% the actual body in body_data/2.
	    {ok, Body}
	end.

%% Prevent people from trying to access directories/files
%% relative to the ServerRoot.
validate_uri(RequestURI) ->
    UriNoQueryNoHex = 
	case string:str(RequestURI, "?") of
	    0 ->
		(catch httpd_util:decode_hex(RequestURI));
	    Ndx ->
		(catch httpd_util:decode_hex(string:left(RequestURI, Ndx)))	
	end,
    case UriNoQueryNoHex of
	{'EXIT',_Reason} ->
	    {error, {bad_request, {malformed_syntax, RequestURI}}};
	_ ->
	    Path = format_request_uri(UriNoQueryNoHex),
	    Path2=[X||X<-string:tokens(Path, "/"),X=/="."], %% OTP-5938
	    validate_path( Path2,0, RequestURI)
    end.

validate_path([], _, _) ->
    ok;
validate_path([".." | _], 0, RequestURI) ->
    {error, {bad_request, {forbidden, RequestURI}}};
validate_path([".." | Rest], N, RequestURI) ->
    validate_path(Rest, N - 1, RequestURI);
validate_path([_ | Rest], N, RequestURI) ->
    validate_path(Rest, N + 1, RequestURI).

%%----------------------------------------------------------------------
%% There are 3 possible forms of the reuqest URI 
%%
%%  1. * When the request is not for a special assset. is is instead
%%     to the server itself
%%
%%  2. absoluteURI the whole servername port and asset is in the request
%%
%%  3. The most common form that http/1.0 used abs path that is a path
%%     to the requested asset.
%%----------------------------------------------------------------------
format_request_uri("*")->
    "*";
format_request_uri("http://" ++ ServerAndPath) ->
   remove_server(ServerAndPath);

format_request_uri("HTTP://" ++ ServerAndPath) ->
    remove_server(ServerAndPath);

format_request_uri(ABSPath) ->
    ABSPath.

remove_server([]) ->
    "/";
remove_server([$\/|Url])->
    case Url of
	[]->
	    "/";
        _->
	    [$\/|Url]
    end;
remove_server([_|Url]) ->
    remove_server(Url).

format_absolute_uri("http://"++ Uri, _)->
    "HTTP://" ++ Uri;

format_absolute_uri(OrigUri = "HTTP://" ++ _, _)->
    OrigUri;

format_absolute_uri(Uri,ParsedHeader)->
    case httpd_util:key1search(ParsedHeader,"host") of
	undefined ->
	    nohost;
	Host ->
	    Host++Uri
    end.

get_persistens(HTTPVersion,ParsedHeader,ConfigDB)->
    case httpd_util:lookup(ConfigDB, persistent_conn, true) of
	true->
	    case HTTPVersion of
		%%If it is version prio to 1.1 kill the conneciton
		"HTTP/1." ++ NList ->
		    case httpd_util:key1search(ParsedHeader,
					       "connection", "keep-alive") of  
			%%if the connection isnt ordered to go down
			%%let it live The keep-alive value is the
			%%older http/1.1 might be older Clients that
			%%use it.
			"keep-alive" when hd(NList) >= 49 ->
			    ?DEBUG("CONNECTION MODE: ~p",[true]),  
			    true;
			"close" ->
			    ?DEBUG("CONNECTION MODE: ~p",[false]),  
			    false;
			_Connect ->
  			    ?DEBUG("CONNECTION MODE: ~p VALUE: ~p",
				   [false, _Connect]),  
			    false
		    end; 
		_ ->
		    ?DEBUG("CONNECTION MODE: ~p VERSION: ~p",
			   [false, HTTPVersion]),  
		    false
	    end;
	_ ->
	    false
    end.


%%----------------------------------------------------------------------
%% tagup_header
%%
%% Parses the header of a HTTP request and returns a key,value tuple 
%% list containing Name and Value of each header directive as of:
%%
%% Content-Type: multipart/mixed -> {"Content-Type", "multipart/mixed"}
%%
%% But in http/1.1 the field-names are case insencitive so now it must be 
%% Content-Type: multipart/mixed -> {"content-type", "multipart/mixed"}
%% The standard furthermore says that leading and traling white space 
%% is not a part of the fieldvalue and shall therefore be removed.
%%----------------------------------------------------------------------
tagup_header([]) ->          [];
tagup_header([Line|Rest]) -> [tag(Line, [])|tagup_header(Rest)].

tag([], Tag) ->
    {http_util:to_lower(lists:reverse(Tag)), ""};
tag([$:|Rest], Tag) ->
    {http_util:to_lower(lists:reverse(Tag)), string:strip(Rest)};
tag([Chr|Rest], Tag) ->
    tag(Rest, [Chr|Tag]).

