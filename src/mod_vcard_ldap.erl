%%%-------------------------------------------------------------------
%%% File    : mod_vcard_ldap.erl
%%% Author  : Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% Created : 29 Jul 2016 by Evgeny Khramtsov <ekhramtsov@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2018   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%----------------------------------------------------------------------

-module(mod_vcard_ldap).

-behaviour(gen_server).
-behaviour(mod_vcard).

%% API
-export([start_link/2]).
-export([init/2, stop/1, get_vcard/2, set_vcard/4, search/4,
	 remove_user/2, import/3, search_fields/1, search_reported/1,
	 mod_opt_type/1, mod_options/1]).
-export([is_search_supported/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include("ejabberd.hrl").
-include("logger.hrl").
-include("eldap.hrl").
-include("xmpp.hrl").
-include("translate.hrl").

-define(PROCNAME, ejabberd_mod_vcard_ldap).

-record(state,
	{serverhost = <<"">>        :: binary(),
         myhosts = []               :: [binary()],
         eldap_id = <<"">>          :: binary(),
         search = false             :: boolean(),
         servers = []               :: [binary()],
         backups = []               :: [binary()],
	 port = ?LDAP_PORT          :: inet:port_number(),
         tls_options = []           :: list(),
         dn = <<"">>                :: binary(),
         base = <<"">>              :: binary(),
         password = <<"">>          :: binary(),
         uids = []                  :: [{binary()} | {binary(), binary()}],
         vcard_map = []             :: [{binary(), binary(), [binary()]}],
	 vcard_map_attrs = []       :: [binary()],
         user_filter = <<"">>       :: binary(),
         search_filter              :: eldap:filter(),
	 search_fields = []         :: [{binary(), binary()}],
         search_reported = []       :: [{binary(), binary()}],
         search_reported_attrs = [] :: [binary()],
	 deref_aliases = never      :: never | searching | finding | always,
         matches = 0                :: non_neg_integer()}).

%%%===================================================================
%%% API
%%%===================================================================
start_link(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:start_link({local, Proc}, ?MODULE, [Host, Opts], []).

init(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ChildSpec = {Proc, {?MODULE, start_link, [Host, Opts]},
		 transient, 1000, worker, [?MODULE]},
    supervisor:start_child(ejabberd_backend_sup, ChildSpec).

stop(Host) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    supervisor:terminate_child(ejabberd_backend_sup, Proc),
    supervisor:delete_child(ejabberd_backend_sup, Proc),
    ok.

is_search_supported(_LServer) ->
    true.

get_vcard(LUser, LServer) ->
    {ok, State} = eldap_utils:get_state(LServer, ?PROCNAME),
    VCardMap = State#state.vcard_map,
    case find_ldap_user(LUser, State) of
	#eldap_entry{attributes = Attributes} ->
	    VCard = ldap_attributes_to_vcard(Attributes, VCardMap,
					     {LUser, LServer}),
	    {ok, [xmpp:encode(VCard)]};
	_ ->
	    {ok, []}
    end.

set_vcard(_LUser, _LServer, _VCard, _VCardSearch) ->
    {atomic, not_implemented}.

search_fields(LServer) ->
    {ok, State} = eldap_utils:get_state(LServer, ?PROCNAME),
    State#state.search_fields.

search_reported(LServer) ->
    {ok, State} = eldap_utils:get_state(LServer, ?PROCNAME),
    State#state.search_reported.

search(LServer, Data, _AllowReturnAll, MaxMatch) ->
    {ok, State} = eldap_utils:get_state(LServer, ?PROCNAME),
    Base = State#state.base,
    SearchFilter = State#state.search_filter,
    Eldap_ID = State#state.eldap_id,
    UIDs = State#state.uids,
    ReportedAttrs = State#state.search_reported_attrs,
    Filter = eldap:'and'([SearchFilter,
			  eldap_utils:make_filter(Data, UIDs)]),
    case eldap_pool:search(Eldap_ID,
			   [{base, Base}, {filter, Filter}, {limit, MaxMatch},
			    {deref_aliases, State#state.deref_aliases},
			    {attributes, ReportedAttrs}])
	of
      #eldap_search_result{entries = E} ->
	  search_items(E, State);
      _ ->
	  []
    end.

search_items(Entries, State) ->
    LServer = State#state.serverhost,
    SearchReported = State#state.search_reported,
    VCardMap = State#state.vcard_map,
    UIDs = State#state.uids,
    Attributes = lists:map(fun (E) ->
				   #eldap_entry{attributes = Attrs} = E, Attrs
			   end,
			   Entries),
    lists:filtermap(
      fun(Attrs) ->
	      case eldap_utils:find_ldap_attrs(UIDs, Attrs) of
		  {U, UIDAttrFormat} ->
		      case eldap_utils:get_user_part(U, UIDAttrFormat) of
			  {ok, Username} ->
			      case ejabberd_auth:user_exists(Username,
								LServer) of
				  true ->
				      RFields = lists:map(
						  fun({_, VCardName}) ->
							  {VCardName,
							   map_vcard_attr(VCardName,
									  Attrs,
									  VCardMap,
									  {Username,
									   ?MYNAME})}
						  end,
						  SearchReported),
				      J = <<Username/binary, $@, LServer/binary>>,
				      {true, [{<<"jid">>, J} | RFields]};
				  _ ->
				      false
			      end;
			  _ ->
			      false
		      end;
		  <<"">> ->
		      false
	      end
      end, Attributes).

remove_user(_User, _Server) ->
    {atomic, not_implemented}.

import(_, _, _) ->
    ok.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init([Host, Opts]) ->
    process_flag(trap_exit, true),
    State = parse_options(Host, Opts),
    eldap_pool:start_link(State#state.eldap_id,
			  State#state.servers, State#state.backups,
			  State#state.port, State#state.dn,
			  State#state.password, State#state.tls_options),
    {ok, State}.

handle_call(get_state, _From, State) ->
    {reply, {ok, State}, State};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
find_ldap_user(User, State) ->
    Base = State#state.base,
    RFC2254_Filter = State#state.user_filter,
    Eldap_ID = State#state.eldap_id,
    VCardAttrs = State#state.vcard_map_attrs,
    case eldap_filter:parse(RFC2254_Filter,
			    [{<<"%u">>, User}])
	of
      {ok, EldapFilter} ->
	  case eldap_pool:search(Eldap_ID,
				 [{base, Base}, {filter, EldapFilter},
				  {deref_aliases, State#state.deref_aliases},
				  {attributes, VCardAttrs}])
	      of
	    #eldap_search_result{entries = [E | _]} -> E;
	    _ -> false
	  end;
      _ -> false
    end.

ldap_attributes_to_vcard(Attributes, VCardMap, UD) ->
    Attrs = lists:map(fun ({VCardName, _, _}) ->
			      {stringprep:tolower(VCardName),
			       map_vcard_attr(VCardName, Attributes, VCardMap,
					      UD)}
		      end,
		      VCardMap),
    lists:foldl(fun ldap_attribute_to_vcard/2, #vcard_temp{}, Attrs).

-spec ldap_attribute_to_vcard({binary(), binary()}, vcard_temp()) -> vcard_temp().
ldap_attribute_to_vcard({Attr, Value}, V) ->
    Ts = V#vcard_temp.tel,
    Es = V#vcard_temp.email,
    N = case V#vcard_temp.n of
	    undefined -> #vcard_name{};
	    _ -> V#vcard_temp.n
	end,
    O = case V#vcard_temp.org of
	    undefined -> #vcard_org{};
	    _ -> V#vcard_temp.org
	end,
    A = case V#vcard_temp.adr of
	    [] -> #vcard_adr{};
	    As -> hd(As)
	end,
    case Attr of
	<<"fn">> -> V#vcard_temp{fn = Value};
	<<"nickname">> -> V#vcard_temp{nickname = Value};
	<<"title">> -> V#vcard_temp{title = Value};
	<<"bday">> -> V#vcard_temp{bday = Value};
	<<"url">> -> V#vcard_temp{url = Value};
	<<"desc">> -> V#vcard_temp{desc = Value};
	<<"role">> -> V#vcard_temp{role = Value};
	<<"tel">> -> V#vcard_temp{tel = [#vcard_tel{number = Value}|Ts]};
	<<"email">> -> V#vcard_temp{email = [#vcard_email{userid = Value}|Es]};
	<<"photo">> -> V#vcard_temp{photo = #vcard_photo{binval = Value}};
	<<"family">> -> V#vcard_temp{n = N#vcard_name{family = Value}};
	<<"given">> -> V#vcard_temp{n = N#vcard_name{given = Value}};
	<<"middle">> -> V#vcard_temp{n = N#vcard_name{middle = Value}};
	<<"orgname">> -> V#vcard_temp{org = O#vcard_org{name = Value}};
	<<"orgunit">> -> V#vcard_temp{org = O#vcard_org{units = [Value]}};
	<<"locality">> -> V#vcard_temp{adr = [A#vcard_adr{locality = Value}]};
	<<"street">> -> V#vcard_temp{adr = [A#vcard_adr{street = Value}]};
	<<"ctry">> -> V#vcard_temp{adr = [A#vcard_adr{ctry = Value}]};
	<<"region">> -> V#vcard_temp{adr = [A#vcard_adr{region = Value}]};
	<<"pcode">> -> V#vcard_temp{adr = [A#vcard_adr{pcode = Value}]};
	_ -> V
    end.

map_vcard_attr(VCardName, Attributes, Pattern, UD) ->
    Res = lists:filter(fun ({Name, _, _}) ->
			       eldap_utils:case_insensitive_match(Name,
								  VCardName)
		       end,
		       Pattern),
    case Res of
      [{_, Str, Attrs}] ->
	  process_pattern(Str, UD,
			  [eldap_utils:get_ldap_attr(X, Attributes)
			   || X <- Attrs]);
      _ -> <<"">>
    end.

process_pattern(Str, {User, Domain}, AttrValues) ->
    eldap_filter:do_sub(Str,
			[{<<"%u">>, User}, {<<"%d">>, Domain}] ++
			  [{<<"%s">>, V, 1} || V <- AttrValues]).

default_vcard_map() ->
    [{<<"NICKNAME">>, [{<<"%u">>, []}]},
     {<<"FN">>, [{<<"%s">>, [<<"displayName">>]}]},
     {<<"FAMILY">>, [{<<"%s">>, [<<"sn">>]}]},
     {<<"GIVEN">>, [{<<"%s">>, [<<"givenName">>]}]},
     {<<"MIDDLE">>, [{<<"%s">>, [<<"initials">>]}]},
     {<<"ORGNAME">>, [{<<"%s">>, [<<"o">>]}]},
     {<<"ORGUNIT">>, [{<<"%s">>, [<<"ou">>]}]},
     {<<"CTRY">>, [{<<"%s">>, [<<"c">>]}]},
     {<<"LOCALITY">>, [{<<"%s">>, [<<"l">>]}]},
     {<<"STREET">>, [{<<"%s">>, [<<"street">>]}]},
     {<<"REGION">>, [{<<"%s">>, [<<"st">>]}]},
     {<<"PCODE">>, [{<<"%s">>, [<<"postalCode">>]}]},
     {<<"TITLE">>, [{<<"%s">>, [<<"title">>]}]},
     {<<"URL">>, [{<<"%s">>, [<<"labeleduri">>]}]},
     {<<"DESC">>, [{<<"%s">>, [<<"description">>]}]},
     {<<"TEL">>, [{<<"%s">>, [<<"telephoneNumber">>]}]},
     {<<"EMAIL">>, [{<<"%s">>, [<<"mail">>]}]},
     {<<"BDAY">>, [{<<"%s">>, [<<"birthDay">>]}]},
     {<<"ROLE">>, [{<<"%s">>, [<<"employeeType">>]}]},
     {<<"PHOTO">>, [{<<"%s">>, [<<"jpegPhoto">>]}]}].

default_search_fields() ->
    [{?T("User"), <<"%u">>},
     {?T("Full Name"), <<"displayName">>},
     {?T("Given Name"), <<"givenName">>},
     {?T("Middle Name"), <<"initials">>},
     {?T("Family Name"), <<"sn">>},
     {?T("Nickname"), <<"%u">>},
     {?T("Birthday"), <<"birthDay">>},
     {?T("Country"), <<"c">>},
     {?T("City"), <<"l">>},
     {?T("Email"), <<"mail">>},
     {?T("Organization Name"), <<"o">>},
     {?T("Organization Unit"), <<"ou">>}].

default_search_reported() ->
    [{?T("Full Name"), <<"FN">>},
     {?T("Given Name"), <<"FIRST">>},
     {?T("Middle Name"), <<"MIDDLE">>},
     {?T("Family Name"), <<"LAST">>},
     {?T("Nickname"), <<"NICK">>},
     {?T("Birthday"), <<"BDAY">>},
     {?T("Country"), <<"CTRY">>},
     {?T("City"), <<"LOCALITY">>},
     {?T("Email"), <<"EMAIL">>},
     {?T("Organization Name"), <<"ORGNAME">>},
     {?T("Organization Unit"), <<"ORGUNIT">>}].

parse_options(Host, Opts) ->
    MyHosts = gen_mod:get_opt_hosts(Host, Opts),
    Search = gen_mod:get_opt(search, Opts),
    Matches = gen_mod:get_opt(matches, Opts),
    Eldap_ID = misc:atom_to_binary(gen_mod:get_module_proc(Host, ?PROCNAME)),
    Cfg = eldap_utils:get_config(Host, Opts),
    UIDsTemp = gen_mod:get_opt(ldap_uids, Opts),
    UIDs = eldap_utils:uids_domain_subst(Host, UIDsTemp),
    SubFilter = eldap_utils:generate_subfilter(UIDs),
    UserFilter = case gen_mod:get_opt(ldap_filter, Opts) of
                     <<"">> ->
			 SubFilter;
                     F ->
                         <<"(&", SubFilter/binary, F/binary, ")">>
                 end,
    {ok, SearchFilter} =
	eldap_filter:parse(eldap_filter:do_sub(UserFilter,
					       [{<<"%u">>, <<"*">>}])),
    VCardMap = gen_mod:get_opt(ldap_vcard_map, Opts),
    SearchFields = gen_mod:get_opt(ldap_search_fields, Opts),
    SearchReported = gen_mod:get_opt(ldap_search_reported, Opts),
    UIDAttrs = [UAttr || {UAttr, _} <- UIDs],
    VCardMapAttrs = lists:usort(lists:append([A
					      || {_, _, A} <- VCardMap])
				  ++ UIDAttrs),
    SearchReportedAttrs = lists:usort(lists:flatmap(fun ({_,
							  N}) ->
							    case
							      lists:keysearch(N,
									      1,
									      VCardMap)
								of
							      {value,
							       {_, _, L}} ->
								  L;
							      _ -> []
							    end
						    end,
						    SearchReported)
					++ UIDAttrs),
    #state{serverhost = Host, myhosts = MyHosts,
	   eldap_id = Eldap_ID, search = Search,
	   servers = Cfg#eldap_config.servers,
	   backups = Cfg#eldap_config.backups,
           port = Cfg#eldap_config.port,
	   tls_options = Cfg#eldap_config.tls_options,
	   dn = Cfg#eldap_config.dn,
           password = Cfg#eldap_config.password,
           base = Cfg#eldap_config.base,
           deref_aliases = Cfg#eldap_config.deref_aliases,
	   uids = UIDs, vcard_map = VCardMap,
	   vcard_map_attrs = VCardMapAttrs,
	   user_filter = UserFilter, search_filter = SearchFilter,
	   search_fields = SearchFields,
	   search_reported = SearchReported,
	   search_reported_attrs = SearchReportedAttrs,
	   matches = Matches}.

mod_opt_type(ldap_search_fields) ->
    fun (Ls) ->
	    [{iolist_to_binary(S), iolist_to_binary(P)}
	     || {S, P} <- Ls]
    end;
mod_opt_type(ldap_search_reported) ->
    fun (Ls) ->
	    [{iolist_to_binary(S), iolist_to_binary(P)}
	     || {S, P} <- Ls]
    end;
mod_opt_type(ldap_vcard_map) ->
    fun (Ls) ->
	    lists:map(fun ({S, [{P, L}]}) ->
			      {iolist_to_binary(S), iolist_to_binary(P),
			       [iolist_to_binary(E) || E <- L]}
		      end,
		      Ls)
    end;
mod_opt_type(Opt) ->
    eldap_utils:opt_type(Opt).

mod_options(Host) ->
    [{ldap_search_fields, default_search_fields()},
     {ldap_search_reported, default_search_reported()},
     {ldap_vcard_map, default_vcard_map()}
     | lists:map(
	 fun({Opt, Default}) ->
		 {Opt, ejabberd_config:get_option({Opt, Host}, Default)}
	 end, eldap_utils:options(Host))].
