%%==============================================================================
%% @author Gavin M. Roy <gavinr@aweber.com>
%% @copyright 2014-2015 AWeber Communications
%% @end
%%==============================================================================

%% @doc define the runtime parameters and validators to setup policies
%% @end

-module(influxdb_storage_parameters).

-behaviour(rabbit_policy_validator).

-export([register/0,
         unregister/0,
         validate_policy/1]).

-define(RUNTIME_PARAMETERS,
        [{policy_validator,  <<"influxdb-scheme">>},
         {policy_validator,  <<"influxdb-host">>},
         {policy_validator,  <<"influxdb-port">>},
         {policy_validator,  <<"influxdb-dbname">>},
         {policy_validator,  <<"influxdb-user">>},
         {policy_validator,  <<"influxdb-password">>},
         {policy_validator,  <<"influxdb-mime-match">>}]).

-rabbit_boot_step({?MODULE,
                   [{description, "influxdb_storage_exchange parameters"},
                    {mfa, {?MODULE, register, []}},
                    {requires, rabbit_registry},
                    {cleanup, {?MODULE, unregister, []}},
                    {enables, recovery}]}).

register() ->
  [rabbit_registry:register(Class, Name, ?MODULE) ||
      {Class, Name} <- ?RUNTIME_PARAMETERS],
  ok.

unregister() ->
    [rabbit_registry:unregister(Class, Name) ||
        {Class, Name} <- ?RUNTIME_PARAMETERS],
    ok.

validate_policy(KeyList) ->
  Scheme   = proplists:get_value(<<"influxdb-scheme">>, KeyList, none),
  Host     = proplists:get_value(<<"influxdb-host">>, KeyList, none),
  Port     = proplists:get_value(<<"influxdb-port">>, KeyList, none),
  DBName   = proplists:get_value(<<"influxdb-dbname">>, KeyList, none),
  User     = proplists:get_value(<<"influxdb-user">>, KeyList, none),
  Password = proplists:get_value(<<"influxdb-password">>, KeyList, none),
  Mime = proplists:get_value(<<"influxdb-mime-match">>, KeyList, none),
  Validation = [influxdb_storage_lib:validate_scheme(Scheme),
                influxdb_storage_lib:validate_host(Host),
                influxdb_storage_lib:validate_port(Port),
                influxdb_storage_lib:validate_dbname(DBName),
                influxdb_storage_lib:validate_user(User),
                influxdb_storage_lib:validate_password(Password),
                influxdb_storage_lib:validate_mime_match(Mime)],
  case Validation of
    [ok, ok, ok, ok, ok, ok, ok]             -> ok;
    [{error, Error}, _, _, _, _, _, _]       -> {error, Error, []};
    [ok, {error, Error}, _, _, _, _, _]      -> {error, Error, []};
    [ok, ok, {error, Error}, _, _, _, _]     -> {error, Error, []};
    [ok, ok, ok, {error, Error}, _, _, _]    -> {error, Error, []};
    [ok, ok, ok, ok, {error, Error}, _, _]   -> {error, Error, []};
    [ok, ok, ok, ok, ok, {error, Error}, _]  -> {error, Error, []};
    [ok, ok, ok, ok, ok, ok, {error, Error}] -> {error, Error, []}
  end.
