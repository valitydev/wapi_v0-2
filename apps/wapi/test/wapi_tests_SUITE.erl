-module(wapi_tests_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-include_lib("wapi_wallet_dummy_data.hrl").
-include_lib("token_keeper_proto/include/tk_token_keeper_thrift.hrl").

-export([all/0]).
-export([groups/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([init_per_group/2]).
-export([end_per_group/2]).
-export([init_per_testcase/2]).
-export([end_per_testcase/2]).

-export([init/1]).

-export([
    wrong_token_on_preauth_error/1,
    wrong_token_on_auth_error/1,
    map_no_match_error_ok/1,
    map_not_in_range_error_ok/1,
    map_wrong_max_size_error_ok/1,
    map_wrong_min_size_error_ok/1,
    map_wrong_format_error_ok/1,
    map_wrong_type_error_ok/1,
    map_wrong_max_length_error_ok/1,
    map_wrong_min_length_error_ok/1,
    map_not_found_error_ok/1,
    map_schema_violated_error_ok/1,
    map_wrong_body_error_ok/1
]).

% common-api is used since it is the domain used in production RN
% TODO: change to wallet-api (or just omit since it is the default one) when new tokens will be a thing
-define(DOMAIN, <<"common-api">>).

-type test_case_name() :: atom().
-type config() :: [{atom(), any()}].
-type group_name() :: atom().

-behaviour(supervisor).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    {ok, {#{strategy => one_for_all, intensity => 1, period => 1}, []}}.

-spec all() -> [{group, test_case_name()}].
all() ->
    [
        {group, base}
    ].

-spec groups() -> [{group_name(), list(), [test_case_name()]}].
groups() ->
    [
        {base, [], [
            wrong_token_on_preauth_error,
            wrong_token_on_auth_error,
            map_no_match_error_ok,
            map_not_in_range_error_ok,
            map_wrong_max_size_error_ok,
            map_wrong_min_size_error_ok,
            map_wrong_format_error_ok,
            map_wrong_type_error_ok,
            map_wrong_max_length_error_ok,
            map_wrong_min_length_error_ok,
            map_not_found_error_ok,
            map_schema_violated_error_ok,
            map_wrong_body_error_ok
        ]}
    ].

%%
%% starting/stopping
%%
-spec init_per_suite(config()) -> config().
init_per_suite(C) ->
    wapi_ct_helper:init_suite(?MODULE, C).

-spec end_per_suite(config()) -> _.
end_per_suite(C) ->
    _ = wapi_ct_helper:stop_mocked_service_sup(?config(suite_test_sup, C)),
    _ = [application:stop(App) || App <- ?config(apps, C)],
    ok.

-spec init_per_group(group_name(), config()) -> config().
init_per_group(Group, Config) when Group =:= base ->
    Party = genlib:bsuuid(),
    Config1 = [{party, Party} | Config],
    [{context, wapi_ct_helper:get_context(?API_TOKEN)} | Config1];
init_per_group(_, Config) ->
    Config.

-spec end_per_group(group_name(), config()) -> _.
end_per_group(_Group, _C) ->
    ok.

-spec init_per_testcase(test_case_name(), config()) -> config().
init_per_testcase(Name, C) ->
    C1 = wapi_ct_helper:makeup_cfg([wapi_ct_helper:test_case_name(Name), wapi_ct_helper:woody_ctx()], C),
    meck:new(swag_server_wallet_w2_w_handler, [no_link, passthrough]),
    [{test_sup, wapi_ct_helper:start_mocked_service_sup(?MODULE)} | C1].

-spec end_per_testcase(test_case_name(), config()) -> ok.
end_per_testcase(_Name, C) ->
    _ = wapi_ct_helper:stop_mocked_service_sup(?config(test_sup, C)),
    meck:unload(swag_server_wallet_w2_w_handler),
    ok.

%%% Tests

-spec wrong_token_on_preauth_error(config()) -> _.
wrong_token_on_preauth_error(C) ->
    Context = wapi_ct_helper:cfg(context, C),
    Params = #{},
    {Endpoint, PreparedParams, Opts0} = wapi_client_lib:make_request(Context, Params),
    Url = swag_client_wallet_utils:get_url(Endpoint, "/wallet/v0/w2w/transfers"),
    HeadersMap = maps:get(header, PreparedParams),
    Headers = maps:to_list(HeadersMap#{<<"Authorization">> => <<"WrongToken">>}),
    Body = <<"{}">>,
    Opts = Opts0 ++ [with_body],
    {ok, 401, _, _} = hackney:request(
        post,
        Url,
        Headers,
        Body,
        Opts
    ).

-spec wrong_token_on_auth_error(config()) -> _.
wrong_token_on_auth_error(C) ->
    _ = wapi_ct_helper_token_keeper:mock_token(
        fun('Authenticate', _) ->
            {throwing, #token_keeper_InvalidToken{}}
        end,
        C
    ),
    Body = #{
        <<"sender">> => ?STRING,
        <<"receiver">> => ?STRING,
        <<"body">> => #{
            <<"amount">> => ?INTEGER,
            <<"currency">> => ?RUB
        }
    },
    {ok, 401, _, _} = make_request(jsx:encode(Body), C).

-spec map_no_match_error_ok(config()) -> _.
map_no_match_error_ok(C) ->
    mock_spec([{type, 'binary'}, {pattern, "^[A-Z]{3}$"}]),
    {ok, 400, _, Error} = make_request(<<"{}">>, C),
    ExpectedError = make_mapped_error(
        "X-Request-ID", "NoMatch", ""
    ),
    ?assertEqual(ExpectedError, Error).

-spec map_not_in_range_error_ok(config()) -> _.
map_not_in_range_error_ok(C) ->
    mock_spec([{type, 'binary'}, {enum, ['someString']}]),
    {ok, 400, _, Error} = make_request(<<"{}">>, C),
    ExpectedError = make_mapped_error(
        "X-Request-ID", "NotInRange", ""
    ),
    ?assertEqual(ExpectedError, Error).

-spec map_wrong_max_size_error_ok(config()) -> _.
map_wrong_max_size_error_ok(C) ->
    mock_spec([{type, 'integer'}, {format, 'int32'}, {max, 2, inclusive}, {min, 1, inclusive}]),
    {ok, 400, _, Error} = make_request(<<"{}">>, C),
    ExpectedError = make_mapped_error(
        "X-Request-ID", "WrongSize", ""
    ),
    ?assertEqual(ExpectedError, Error).

-spec map_wrong_min_size_error_ok(config()) -> _.
map_wrong_min_size_error_ok(C) ->
    mock_spec([{type, 'integer'}, {format, 'int32'}, {max, 100000001, inclusive}, {min, 100000000, inclusive}]),
    {ok, 400, _, Error} = make_request(<<"{}">>, C),
    ExpectedError = make_mapped_error(
        "X-Request-ID", "WrongSize", ""
    ),
    ?assertEqual(ExpectedError, Error).

-spec map_wrong_format_error_ok(config()) -> _.
map_wrong_format_error_ok(C) ->
    mock_spec([{type, 'binary'}, {format, 'date-time'}]),
    {ok, 400, _, Error} = make_request(<<"{}">>, C),
    ExpectedError = make_mapped_error(
        "X-Request-ID", "WrongFormat", ""
    ),
    ?assertEqual(ExpectedError, Error).

-spec map_wrong_type_error_ok(config()) -> _.
map_wrong_type_error_ok(C) ->
    mock_spec([{type, 'boolean'}]),
    {ok, 400, _, Error} = make_request(<<"{}">>, C),
    ExpectedError = make_mapped_error(
        "X-Request-ID", "WrongType", ""
    ),
    ?assertEqual(ExpectedError, Error).

-spec map_wrong_max_length_error_ok(config()) -> _.
map_wrong_max_length_error_ok(C) ->
    mock_spec([{type, 'binary'}, {max_length, 2}, {min_length, 1}]),
    {ok, 400, _, Error} = make_request(<<"{}">>, C),
    ExpectedError = make_mapped_error(
        "X-Request-ID", "WrongLength", ""
    ),
    ?assertEqual(ExpectedError, Error).

-spec map_wrong_min_length_error_ok(config()) -> _.
map_wrong_min_length_error_ok(C) ->
    mock_spec([{type, 'binary'}, {max_length, 2000}, {min_length, 1999}]),
    {ok, 400, _, Error} = make_request(<<"{}">>, C),
    ExpectedError = make_mapped_error(
        "X-Request-ID", "WrongLength", ""
    ),
    ?assertEqual(ExpectedError, Error).

-spec map_not_found_error_ok(config()) -> _.
map_not_found_error_ok(C) ->
    Context = wapi_ct_helper:cfg(context, C),
    Params = #{},
    {Endpoint, PreparedParams, Opts0} = wapi_client_lib:make_request(Context, Params),
    Url = swag_client_wallet_utils:get_url(Endpoint, "/wallet/v0/w2w/transfers"),
    Headers = maps:to_list(maps:without([<<"X-Request-ID">>], maps:get(header, PreparedParams))),
    Opts = Opts0 ++ [with_body],
    {ok, 400, _, Error} = hackney:request(
        post,
        Url,
        Headers,
        <<"{}">>,
        Opts
    ),
    ExpectedError = make_mapped_error(
        "X-Request-ID", "NotFound", ""
    ),
    ?assertEqual(ExpectedError, Error).

-spec map_schema_violated_error_ok(config()) -> _.
map_schema_violated_error_ok(C) ->
    {ok, 400, _, Error} = make_request(<<"{}">>, C),
    ExpectedError = make_mapped_error(
        "W2WTransferParameters", "SchemaViolated", ", description: Missing required property: body."
    ),
    ?assertEqual(ExpectedError, Error).

-spec map_wrong_body_error_ok(config()) -> _.
map_wrong_body_error_ok(C) ->
    Body = <<"🥲"/utf8>>,
    {ok, 400, _, Error} = make_request(Body, C),
    ExpectedError = make_mapped_error("W2WTransferParameters", "WrongBody", ", description: Invalid json"),
    ?assertEqual(ExpectedError, Error).

make_request(Body, C) ->
    Context = wapi_ct_helper:cfg(context, C),
    Params = #{},
    {Endpoint, PreparedParams, Opts0} = wapi_client_lib:make_request(Context, Params),
    Url = swag_client_wallet_utils:get_url(Endpoint, "/wallet/v0/w2w/transfers"),
    Headers = maps:to_list(maps:get(header, PreparedParams)),
    Opts = Opts0 ++ [with_body],
    hackney:request(
        post,
        Url,
        Headers,
        Body,
        Opts
    ).

make_mapped_error(Name, Type, Desc) ->
    Format = <<"{\"description\":\"Request parameter: ~s, error type: ~s~s\",\"errorType\":\"~s\",\"name\":\"~s\"}">>,
    genlib:to_binary(io_lib:format(Format, [Name, Type, Desc, Type, Name])).

%% Dirty hack to mock private get_request_spec function of swag_server_wallet_w2_w_handler module
%% by mocking highlevel handle_request_json function (implemeptetion of handle_request_json and state record
%% copied from swag_server_wallet_w2_w_handler).
%% If generated code changes in unsupported way we can drop this hack
%% and use spec rules from generated code and dont cover all test cases, only possible.

mock_spec(Rules) ->
    meck:expect(
        swag_server_wallet_w2_w_handler,
        handle_request_json,
        fun(Req, State) ->
            handle_request_json(Req, State, Rules)
        end
    ).

-record(state, {
    operation_id :: swag_server_wallet:operation_id(),
    logic_handler :: module(),
    swagger_handler_opts :: swag_server_wallet_router:swagger_handler_opts(),
    context :: swag_server_wallet:request_context()
}).

handle_request_json(
    Req0,
    State = #state{
        operation_id = OperationID,
        logic_handler = LogicHandler,
        swagger_handler_opts = SwaggerHandlerOpts,
        context = Context
    },
    Rules
) ->
    ValidationOpts = maps:get(validation_opts, SwaggerHandlerOpts, #{}),
    case populate_request(LogicHandler, OperationID, Req0, ValidationOpts, Rules) of
        {ok, Populated, Req1} ->
            {Status, Resp} = handle_request(LogicHandler, OperationID, Populated, Context),
            ok = validate_response(Status, Resp, OperationID, ValidationOpts),
            process_response(ok, encode_response(Resp), Req1, State);
        {error, Reason, Req1} ->
            process_response(error, Reason, Req1, State)
    end.

populate_request(LogicHandler, OperationID, Req, ValidationOpts, Rules) ->
    Spec = get_request_spec(OperationID, Rules),
    swag_server_wallet_handler_api:populate_request(LogicHandler, OperationID, Spec, Req, ValidationOpts).

handle_request(LogicHandler, OperationID, Populated, Context) ->
    swag_server_wallet_logic_handler:handle_request(LogicHandler, OperationID, Populated, Context).

validate_response(error, _, _, _) ->
    ok;
validate_response(ok, {Code, _Headers, Body}, OperationID, ValidationOpts) ->
    Spec = get_response_spec(OperationID, Code),
    swag_server_wallet_handler_api:validate_response(OperationID, Spec, Body, ValidationOpts).

encode_response(Resp) ->
    swag_server_wallet_handler_api:encode_response(Resp).

process_response(Status, Result, Req0, State = #state{operation_id = OperationID}) ->
    Req = swag_server_wallet_handler_api:process_response(Status, Result, Req0, OperationID),
    {stop, Req, State}.

get_request_spec('CreateW2WTransfer', Rules) ->
    [
        {'X-Request-ID', #{
            source => header,
            rules => Rules ++
                [
                    true,
                    {required, true}
                ]
        }},
        {'X-Request-Deadline', #{
            source => header,
            rules => [
                {type, 'binary'},
                {max_length, 40},
                {min_length, 1},
                true,
                {required, false}
            ]
        }},
        {'W2WTransferParameters', #{
            source => body,
            rules => [schema, {required, false}]
        }}
    ].

get_response_spec('CreateW2WTransfer', 202) ->
    {'W2WTransfer', 'W2WTransfer'};
get_response_spec('CreateW2WTransfer', 400) ->
    {'BadRequest', 'BadRequest'};
get_response_spec('CreateW2WTransfer', 401) ->
    undefined;
get_response_spec('CreateW2WTransfer', 409) ->
    {'ConflictRequest', 'ConflictRequest'};
get_response_spec('CreateW2WTransfer', 422) ->
    {'InvalidOperationParameters', 'InvalidOperationParameters'};
get_response_spec(OperationID, Code) ->
    error({invalid_response_code, OperationID, Code}).
