%%==============================================================================
%% @author Gavin M. Roy <gavinr@aweber.com>
%% @copyright 2014-2015 AWeber Communications
%% @end
%%==============================================================================

%% @doc Abstract away the validation and event submission functionality from
%%      the exchange module
%% @end

-module(influxdb_storage_lib).

-include_lib("rabbit_common/include/rabbit.hrl").
-include_lib("rabbit_common/include/rabbit_framing.hrl").

-export([post/2,
         validate/1]).

-export([build_json/3,
         get_env/2,
         get_param/3,
         get_param_env_value/2,
         get_param_list_value/1,
         get_param_value/3,
         get_payload/1,
         get_port/1,
         get_url/2,
         validate_dbname/1,
         validate_host/1,
         validate_string_or_none/2,
         validate_mime_match/1,
         validate_scheme/1,
         validate_password/1,
         validate_port/1,
         validate_user/1]).

-define(DEFAULT_SCHEME,   "http").
-define(DEFAULT_HOST,     "localhost").
-define(DEFAULT_PORT,     8086).
-define(DEFAULT_USER,     "rabbitmq").
-define(DEFAULT_PASSWORD, "influxdb").
-define(DEFAULT_DBNAME,   "influxdb").

post(X,
     #delivery{message=#basic_message{routing_keys=Keys,
                                      content=Content}}) ->
  Key = list_to_binary(lists:append([binary_to_list(K) || K <- Keys])),
  Properties = (Content#content.properties),
  case Properties#'P_basic'.content_type of
    <<"application/json">> ->
      case build_json(Key, get_payload(Content), Properties#'P_basic'.timestamp) of
        {ok, Payload} ->
          case ibrowse:send_req(get_url(X, series),
                                      [{"Content-type", "application/json"}],
                                      post,
                                      Payload,
                                      [{max_sessions, 10},
                                       {max_pipeline_size, 1}]) of
            {ok, "200", _, _}   -> ok;
            {ok, _, _, Content} -> {error, list_to_binary(Content)};
            {error, Error}      -> {error, Error}
          end;
        {error, Error} ->
          rabbit_error:log("influx_storage_exchange ignoring msg: ~p~n", [Error]),
          ignored
      end;
    _ ->
      ignored
  end.

%% @spec validate(X) -> Result
%% @where
%%       Value  = rabbit_type:exchange()
%%       Result = ok|{error, Error}
%% @doc Validate the user specified dbname is a binary value or none
%% @end
%%
validate(X) ->
  case  ibrowse:send_req(get_url(X, authenticate), [], get) of
      {ok, "200", _, _  } -> ok;
      {ok, _, _, Content} -> {error, list_to_binary(Content)};
      {error, {Error, _}} -> {error, Error}
  end.

%% @spec validate_dbname(Value) -> Result
%% @where
%%       Value  = binary()|list()|none
%%       Result = ok|{error, Error}
%% @doc Validate the user specified dbname is a binary value or none
%% @end
%%
validate_dbname(none) -> ok;
validate_dbname(Value) ->
  validate_string_or_none("influxdb-dbname", Value).

%% @spec validate_host(Value) -> Result
%% @where
%%       Value  = binary()|list()|none
%%       Result = ok|{error, Error}
%% @doc Validate the user specified hostname is a binary or none
%% @end
%%
validate_host(none) -> ok;
validate_host(Value) ->
  validate_string_or_none("influxdb-host", Value).

%% @spec validate_mime_match(Value) -> Result
%% @where
%%       Value  = atom()|none
%%       Result = ok|{error, Error}
%% @doc Validate the user specified mime-match value is true/false/none
%% @end
%%
validate_mime_match(none) -> ok;
validate_mime_match(false) -> ok;
validate_mime_match(true) -> ok;
validate_mime_match(_) -> {error, "influxdb-mime-match should be a boolean"}.

%% @spec validate_password(Value) -> Result
%% @where
%%       Value  = binary()|none
%%       Result = ok|{error, Error}
%% @doc Validate the user specified password is a binary or none
%% @end
%%
validate_password(none) -> ok;
validate_password(Value) ->
  validate_string_or_none("influxdb-password", Value).

%% @spec validate_port(Value) -> Result
%% @where
%%       Value  = integer()|none
%%       Result = ok|{error, Error}
%% @doc Validate the user specified port is an integer value or none
%% @end
%%
validate_port(none) -> ok;
validate_port(Value) when is_number(Value) -> ok;
validate_port(_) -> {error, "influxdb-port should be an integer"}.

%% @spec validate_scheme(Value) -> Result
%% @where
%%       Value  = list()|binary()|none
%%       Result = ok|{error, Error}
%% @doc Validate the protocol scheme specified user is a binary value or none
%% @end
%%
validate_scheme(none) -> ok;
validate_scheme(Value) ->
  validate_string_or_none("influxdb-scheme", Value).

%% @spec validate_user(Value) -> Result
%% @where
%%       Value  = list()|binary()|none
%%       Result = ok|{error, Error}
%% @doc Validate the user specified user is a binary value or none
%% @end
%%
validate_user(none) -> ok;
validate_user(Value) ->
  validate_string_or_none("influxdb-user", Value).

%% ---------------
%% Private Methods
%% ---------------

%% @private
%% @spec build_json(Name, JSON, Timestamp) -> list()
%% @where
%%       Name         = list()
%%       JSON         = list()
%%       Timestamp    = integer()|undefined
%% @doc Build the influxdb JSON payload as a pivoted version of the payload that
%%      was passed in. If timestamp is not undefined, it is injected into the
%%      columns and points.
%% @end
%%
build_json(Name, JSON, Timestamp) ->
  case rabbit_misc:json_decode(JSON) of
    {ok, {struct, D1}} ->
      D2 = dict:from_list(D1),
      C1 = dict:fetch_keys(D2),
      case Timestamp of
        undefined ->
          Columns = C1,
          Points = [dict:fetch(K, D2) || K <- C1];
        _ ->
          Columns = lists:append([<<"time">>], dict:fetch_keys(D2)),
          Points = lists:append([Timestamp], [dict:fetch(K, D2) || K <- C1])
      end,
      Payload = {array, [{struct, [{"name", Name},
                                   {"columns", {array, [K || K <- Columns]}},
                                   {"points", {array, [{array, Points}]}}]}]},
      rabbit_misc:json_encode(Payload);
    error ->
      {error, json_decoding_error}
  end.

%% @private
%% @spec get_env(EnvVar, DefaultValue) -> Value
%% @where
%%       Name         = list()
%%       DefaultValue = mixed
%%       Value        = mixed
%% @doc Return the environment variable defined for listen returning the
%%      value if the variable is found, otherwise return the passed in default
%% @end
%%
get_env(EnvVar, DefaultValue) ->
  case application:get_env(listen, EnvVar) of
    undefined ->
      DefaultValue;
    {ok, V} ->
      V
  end.

%% @private
%% @spec get_parm(X, Name, DefaultValue) -> Value
%% @where
%%       X            = rabbit_types:exchange()
%%       Name         = list()|atom()
%%       DefaultValue = mixed
%%       Value        = mixed
%% @doc Returns the configuration value for an exchange, first by checking to
%% see if a policy value is set for the exchange, then by checking arguments in
%% the exchange, then checking environment defined overrides (config), and
%% finally by returning the passed in default value
%% @end
%%
get_param(X, Name, DefaultValue) when is_atom(Name) ->
  get_param(X, atom_to_list(Name), DefaultValue);

get_param(#exchange{arguments=Args, policy=Policy}, Name, DefaultValue) when Policy =:= undefined ->
    get_param_value(Args, Name, DefaultValue);

get_param(X=#exchange{arguments=Args}, Name, DefaultValue) when is_list(Name) ->
  case rabbit_policy:get(list_to_binary("influxdb-" ++ Name), X) of
    undefined -> get_param_value(Args, Name, DefaultValue);
    Value     ->
      case is_binary(Value) of
        true  -> binary_to_list(Value);
        false -> Value
      end
  end.

%% @private
%% @spec get_param_env_value(Name, DefaultValue) -> Value
%% @where
%%       Name         = list()
%%       DefaultValue = mixed
%%       Value        = mixed
%% @doc Return the value specified in the config/environment for the passed in
%% key Name, returning DefaultValue if it's not specified
%% @end
%%
get_param_env_value(Name, DefaultValue ) ->
  get_env(list_to_atom(Name), DefaultValue).

%% @private
%% @spec get_param_list_value(Value) -> list()
%% @where
%%       DefaultValue = binary()|integer()|list()
%% @doc Cast Value to a list if it is binary or an integer
%% @end
%%
get_param_list_value(Value) when is_binary(Value) ->
  binary_to_list(Value);
get_param_list_value(Value) when is_integer(Value) ->
  integer_to_list(Value);
get_param_list_value(Value) when is_list(Value) ->
  Value.

%% @private
%% @spec get_param_value(Args, Name, DefaultValue) -> Value
%% @where
%%       Args         = rabbit_framing:amqp_table()
%%       Name         = list()
%%       DefaultValue = binary()|integer()|list()
%% @doc Return the value of Name from the Args table, falling back to returning
%% the configuration specified env value, or the DefaultValue if it not present
%% in either Args or the config environment.
%% @end
%%
get_param_value(Args, Name, DefaultValue) ->
  case lists:keyfind(list_to_binary("x-" ++ Name), 1, Args) of
    {_, _, V} -> get_param_list_value(V);
            _ -> get_param_list_value(get_param_env_value(Name, DefaultValue))
  end.

%% @private
%% @spec get_payload(Value) -> list()
%% @where
%%       Value = tuple()#content
%% @doc Extract the reverse list of binary payload segments and order it
%%      correctly, converting the binary to list to return the full message
%%      body as a list.
%% @end
%%
get_payload(#content{payload_fragments_rev=Payload}) ->
  lists:append(lists:reverse([binary_to_list(V) || V <- Payload])).

%% @private
%% @spec get_port(Value) -> integer()
%% @where
%%       Value = list()|integer()|none
%% @doc Return the value passed in as an integer if it is a list anf the value
%% if it is an integer
%% @end
%%
get_port(Value) when is_list(Value) -> list_to_integer(Value);
get_port(Value) when is_number(Value) -> Value.

%% @private
%% @spec get_url(X, Type) -> list()
%% @where
%%       X    = rabbit_types:exchange()
%%       Type = atom()
%% @doc Return a properly formatted influxdb URL for the specified type
%%      (authenticate, series, etc)
%% @end
%%
get_url(X, Type) ->
  Scheme   = get_param(X, "scheme", ?DEFAULT_SCHEME),
  Host     = get_param(X, "host", ?DEFAULT_HOST),
  Port     = get_port(get_param(X, "port", ?DEFAULT_PORT)),
  User     = get_param(X, "user", ?DEFAULT_USER),
  Password = get_param(X, "password", ?DEFAULT_PASSWORD),
  DBName   = get_param(X, "dbname", ?DEFAULT_DBNAME),
  Scheme ++ "://" ++ Host ++ ":" ++ integer_to_list(Port) ++ "/db/" ++ DBName
    ++ "/" ++ atom_to_list(Type) ++ "?u=" ++ User ++ "&p=" ++ Password.

%% @private
%% @spec validate_string_or_none(Name, Value) -> Result
%% @doc Validate the user specified value is a list() or none
%% @where
%%       Name   = binary()|list()
%%       Value  = list()|none
%%       Result = ok|{error, Error}
%% @end
%%
validate_string_or_none(_, none) -> ok;
validate_string_or_none(_, Value) when is_binary(Value) -> ok;
validate_string_or_none(_, Value) when is_list(Value) -> ok;
validate_string_or_none(Name, _) ->
    {error, lists:flatten(io_lib:format("~s should be a string", [Name]))}.
