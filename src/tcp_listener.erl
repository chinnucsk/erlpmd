%% Copyright (c) 2012 Peter Lemenkov.
%%
%% The MIT License
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%% THE SOFTWARE.
%%

-module(tcp_listener).

-behaviour(gen_server).

-export([start_link/1]).
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-record(state, {
	listener,
	acceptor,
	clients = []
}).

start_link(Args) ->
	gen_server:start_link(?MODULE, Args, []).

init ([IP, Port]) ->
	Opts = [{ip, IP}, binary, {packet, 2}, {reuseaddr, true}, {keepalive, true}, {backlog, 30}, {active, false}],
	{ok, Socket} = gen_tcp:listen(Port, Opts),
	{ok, Ref} = prim_inet:async_accept(Socket, -1),
	error_logger:info_msg("ErlPMD listener: started at IP: ~s:~b~n", [inet_parse:ntoa(IP), Port]),
	{ok, #state{listener = Socket, acceptor = Ref}}.

handle_call(Other, From, State) ->
	error_logger:warning_msg("ErlPMD listener: strange call: ~p from ~p.~n", [Other, From]),
	{noreply, State}.

handle_cast({msg, Msg, Ip, Port}, State = #state{clients=Clients}) ->
	% Select proper client
	case get_socket(Clients, Ip, Port) of
		error -> ok;
		Fd ->
			inet:setopts(Fd, [{packet, raw}]),
			gen_tcp:send(Fd, Msg),
			inet:setopts(Fd, [{packet, 2}])
	end,
	{noreply, State};

handle_cast({close, Ip, Port}, #state{clients = Clients} = State) ->
	error_logger:info_msg("ErlPMD listener: closing connection: ~s:~b.~n", [inet_parse:ntoa(Ip), Port]),
	case get_socket(Clients, Ip, Port) of
		error ->
			ok;
		Fd ->
			gen_server:cast(erlpmd, {{close, self()}, Fd}),
			gen_tcp:close(Fd)
	end,
	{noreply, State};

handle_cast(stop, State) ->
	{stop, normal, State};

handle_cast(Other, State) ->
	error_logger:warning_msg("ErlPMD listener: strange cast: ~p.~n", [Other]),
	{noreply, State}.

handle_info({tcp, Fd, Msg}, State) ->
	inet:setopts(Fd, [{active, once}, {packet, 2}, binary]),
	{ok, {Ip, Port}} = inet:peername(Fd),
	gen_server:cast(erlpmd, {{msg, self()}, Msg, Fd, Ip, Port}),
	{noreply, State};

handle_info({tcp_closed, Client}, #state{clients = Clients} = State) ->
	gen_tcp:close(Client),
	gen_server:cast(erlpmd, {{close, self()}, Client}),
	error_logger:info_msg("ErlPMD listener: client ~p closed connection.~n", [Client]),
	{noreply, State#state{clients = lists:delete(Client, Clients)}};

handle_info({inet_async, ListSock, Ref, {ok, CliSocket}}, #state{listener = ListSock, acceptor = Ref, clients = Clients} = State) ->
	case set_sockopt(ListSock, CliSocket) of
		ok -> ok;
		{error, Reason} -> exit({set_sockopt, Reason})
	end,

	inet:setopts(CliSocket, [{active, once}, {packet, 2}, binary]),

	case prim_inet:async_accept(ListSock, -1) of
		{ok, NewRef} -> ok;
		{error, NewRef} -> exit({async_accept, inet:format_error(NewRef)})
        end,

	{noreply, State#state{acceptor=NewRef, clients = Clients ++ [CliSocket]}};

handle_info({inet_async, ListSock, Ref, Error}, #state{listener = ListSock, acceptor = Ref} = State) ->
	error_logger:error_msg("ErlPMD listener: error in socket acceptor: ~p.~n", [Error]),
	{stop, Error, State};

handle_info(Info, State) ->
	error_logger:warning_msg("ErlPMD listener: strange info: ~p.~n", [Info]),
	{noreply, State}.

terminate(Reason, #state{listener = Listener, clients = Clients}) ->
	gen_tcp:close(Listener),
	lists:map(fun gen_tcp:close/1, Clients),
	error_logger:error_msg("ErlPMD listener: closed: ~p.~n", [Reason]),
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

set_sockopt(ListSock, CliSocket) ->
	true = inet_db:register_socket(CliSocket, inet_tcp),
	case prim_inet:getopts(ListSock, [active, nodelay, keepalive, delay_send, priority, tos]) of
		{ok, Opts} ->
			case prim_inet:setopts(CliSocket, Opts) of
				ok ->
					ok;
				Error ->
					gen_tcp:close(CliSocket),
					Error
			end;
		Error ->
			gen_tcp:close(CliSocket),
			Error
	end.

get_socket([], _, _) ->
	error;
get_socket([S | Rest], Ip, Port) ->
	case inet:peername(S) of
		{ok, {Ip, Port}} -> S;
		_ -> get_socket(Rest, Ip, Port)
	end.
