-module(wapi_woody_tests_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("wapi_wallet_dummy_data.hrl").

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
    woody_unexpected_test/1,
    woody_unavailable_test/1,
    woody_retry_test/1,
    woody_unknown_test/1,
    woody_deadline_test/1
]).

-define(BADRESP(Code), {error, {invalid_response_code, Code}}).

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
        {group, woody_errors}
    ].

-spec groups() -> [{group_name(), list(), [test_case_name()]}].
groups() ->
    [
        {woody_errors, [], [
            woody_unexpected_test,
            woody_unavailable_test,
            woody_retry_test,
            woody_unknown_test,
            woody_deadline_test
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
    _ = [application:stop(App) || App <- proplists:get_value(apps, C)],
    ok.

-spec init_per_group(group_name(), config()) -> config().
init_per_group(woody_errors, C) ->
    Party = genlib:bsuuid(),
    Context = wapi_ct_helper:get_context(?API_TOKEN),
    SupPid = wapi_ct_helper:start_mocked_service_sup(?MODULE),
    Apps1 = wapi_ct_helper_token_keeper:mock_user_session_token(Party, SupPid),
    Apps2 = wapi_ct_helper_bouncer:mock_arbiter(wapi_ct_helper_bouncer:judge_always_allowed(), SupPid),
    [{context, Context}, {group_apps, Apps1 ++ Apps2}, {group_test_sup, SupPid} | C];
init_per_group(_, C) ->
    C.

-spec end_per_group(group_name(), config()) -> _.
end_per_group(_Group, C) ->
    _ = maybe(?config(group_test_sup, C), fun wapi_ct_helper:stop_mocked_service_sup/1),
    ok.

-spec init_per_testcase(test_case_name(), config()) -> config().
init_per_testcase(_Name, C) ->
    [{test_sup, wapi_ct_helper:start_mocked_service_sup(?MODULE)} | C].

-spec end_per_testcase(test_case_name(), config()) -> _.
end_per_testcase(_Name, C) ->
    wapi_ct_helper:stop_mocked_service_sup(?config(test_sup, C)),
    ok.

%%% Tests

-spec woody_unexpected_test(config()) -> _.
woody_unexpected_test(C) ->
    _ = wapi_ct_helper:mock_services(
        [
            {fistful_destination, fun
                ('GetContext', _) -> {ok, "spanish inquisition"};
                ('Get', _) -> {ok, "spanish inquisition"}
            end}
        ],
        C
    ),
    ?BADRESP(500) = get_destination_call_api(C).

-spec woody_unavailable_test(config()) -> _.
woody_unavailable_test(C) ->
    ok = application:set_env(
        wapi_lib,
        service_urls,
        #{fistful_destination => <<"http://spanish.inquision/v1">>}
    ),
    ?BADRESP(504) = get_destination_call_api(C).

-spec woody_retry_test(config()) -> _.
woody_retry_test(C) ->
    ok = application:set_env(
        wapi_lib,
        service_urls,
        #{fistful_destination => <<"http://spanish.inquision/v1">>}
    ),
    ok = application:set_env(
        wapi_lib,
        service_retries,
        #{
            fistful_destination => #{
                'GetContext' => {linear, 30, 1000},
                'Get' => {linear, 30, 1000},
                '_' => finish
            }
        }
    ),
    ok = application:set_env(
        wapi_lib,
        service_deadlines,
        #{fistful_destination => 5000}
    ),
    {Time, ?BADRESP(504)} = timer:tc(fun get_destination_call_api/1, [C]),
    true = (Time > 3000000) and (Time < 10000000).

-spec woody_unknown_test(config()) -> _.
woody_unknown_test(C) ->
    _ = wapi_ct_helper:mock_services(
        [
            {fistful_destination, fun
                ('GetContext', _) -> timer:sleep(60000);
                ('Get', _) -> timer:sleep(60000)
            end}
        ],
        C
    ),
    ?BADRESP(504) = get_destination_call_api(C).

-spec woody_deadline_test(config()) -> _.
woody_deadline_test(C) ->
    _ = wapi_ct_helper:mock_services(
        [
            {fistful_destination, fun
                ('GetContext', _) -> timer:sleep(1000);
                ('Get', _) -> timer:sleep(1000)
            end}
        ],
        C
    ),
    Context = wapi_ct_helper:cfg(context, C),
    ?BADRESP(504) = call_api(
        fun swag_client_wallet_withdrawals_api:get_destination/3,
        #{
            binding => #{
                <<"destinationID">> => ?STRING
            }
        },
        Context#{deadline => "1ms"}
    ).

-spec call_api(function(), map(), wapi_client_lib:context()) -> {ok, term()} | {error, term()}.
call_api(F, Params, Context) ->
    {Url, PreparedParams, Opts} = wapi_client_lib:make_request(Context, Params),
    Response = F(Url, PreparedParams, Opts),
    wapi_client_lib:handle_response(Response).

get_destination_call_api(C) ->
    call_api(
        fun swag_client_wallet_withdrawals_api:get_destination/3,
        #{
            binding => #{
                <<"destinationID">> => ?STRING
            }
        },
        wapi_ct_helper:cfg(context, C)
    ).

-spec maybe(T | undefined, fun((T) -> R)) -> R | undefined.
maybe(undefined, _Fun) ->
    undefined;
maybe(V, Fun) ->
    Fun(V).
