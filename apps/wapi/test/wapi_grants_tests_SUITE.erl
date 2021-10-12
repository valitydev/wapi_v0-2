-module(wapi_grants_tests_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-include_lib("wapi_wallet_dummy_data.hrl").
-include_lib("wapi_bouncer_data.hrl").

-include_lib("fistful_proto/include/ff_proto_destination_thrift.hrl").
-include_lib("fistful_proto/include/ff_proto_wallet_thrift.hrl").
-include_lib("fistful_proto/include/ff_proto_withdrawal_thrift.hrl").

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
    issue_wallet_grant_ok/1,
    issue_wallet_grant_expired/1,
    issue_destination_grant_ok/1,
    issue_destination_grant_expired/1,
    create_withdrawal_with_both_grants/1
]).

% common-api is used since it is the domain used in production RN
% TODO: change to wallet-api (or just omit since it is the default one) when new tokens will be a thing
-define(DOMAIN, <<"common-api">>).
-define(badresp(Code), {error, {invalid_response_code, Code}}).
-define(emptyresp(Code), {error, {Code, #{}}}).

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
        {group, base},
        {group, ops_with_grants}
    ].

-spec groups() -> [{group_name(), list(), [test_case_name()]}].
groups() ->
    [
        {base, [], [
            issue_wallet_grant_ok,
            issue_wallet_grant_expired,
            issue_destination_grant_ok,
            issue_destination_grant_expired
        ]},
        {ops_with_grants, [], [
            create_withdrawal_with_both_grants
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
init_per_group(Group, Config) when Group =:= ops_with_grants ->
    %% Issue grants as a diffrent party
    ok = init_group_context(Group),
    {Party1, Token1} = make_party_token(),
    C0 = [{party, Party1}, {context, wapi_ct_helper:get_context(Token1)} | Config],
    C1 = wapi_ct_helper:makeup_cfg([wapi_ct_helper:test_case_name(ops_with_grants), wapi_ct_helper:woody_ctx()], C0),
    ok = wapi_context:save(C1),
    {WalletGrant, DestinationGrant} = issue_wallet_and_destination_grant(C1),
    ok = wapi_context:cleanup(),
    %%
    ok = init_group_context(Group),
    {Party2, Token2} = make_party_token(),
    [
        {destination_grant, DestinationGrant},
        {wallet_grant, WalletGrant},
        {granting_party, Party1},
        {party, Party2},
        {context, wapi_ct_helper:get_context(Token2)}
        | Config
    ];
init_per_group(Group, Config) when Group =:= base ->
    ok = init_group_context(Group),
    {Party, Token} = make_party_token(),
    [{party, Party}, {context, wapi_ct_helper:get_context(Token)} | Config];
init_per_group(_, Config) ->
    Config.

make_party_token() ->
    Party = genlib:bsuuid(),
    {ok, Token} = wapi_ct_helper:issue_token(Party, [{[party], write}], unlimited, ?DOMAIN),
    {Party, Token}.

init_group_context(Group) ->
    wapi_context:save(
        wapi_context:create(#{
            woody_context => woody_context:new(<<"init_per_group/", (atom_to_binary(Group, utf8))/binary>>)
        })
    ).

-spec end_per_group(group_name(), config()) -> _.
end_per_group(_Group, _C) ->
    ok.

-spec init_per_testcase(test_case_name(), config()) -> config().
init_per_testcase(Name, C) ->
    C1 = wapi_ct_helper:makeup_cfg([wapi_ct_helper:test_case_name(Name), wapi_ct_helper:woody_ctx()], C),
    ok = wapi_context:save(C1),
    [{test_sup, wapi_ct_helper:start_mocked_service_sup(?MODULE)} | C1].

-spec end_per_testcase(test_case_name(), config()) -> config().
end_per_testcase(_Name, C) ->
    ok = wapi_context:cleanup(),
    _ = wapi_ct_helper:stop_mocked_service_sup(?config(test_sup, C)),
    ok.

%%% Tests

-spec issue_wallet_grant_ok(config()) -> _.
issue_wallet_grant_ok(C) ->
    _ = issue_wallet_grant_start_mocks(C),
    LifeTime = 1000,
    ValidUntil = posix_to_rfc3339(lifetime_to_expiration(LifeTime)),
    ?assertMatch(
        {ok, #{
            <<"token">> := _,
            <<"asset">> := _,
            <<"validUntil">> := ValidUntil
        }},
        issue_wallet_grant_call_api(LifeTime, C)
    ).

-spec issue_wallet_grant_expired(config()) -> _.
issue_wallet_grant_expired(C) ->
    _ = issue_wallet_grant_start_mocks(C),
    LifeTime = -1000,
    ?assertEqual(
        {error, {422, #{<<"message">> => <<"Invalid expiration: already expired">>}}},
        issue_wallet_grant_call_api(LifeTime, C)
    ).

-spec issue_destination_grant_ok(config()) -> _.
issue_destination_grant_ok(C) ->
    _ = issue_destination_grant_start_mocks(C),
    LifeTime = 1000,
    ValidUntil = posix_to_rfc3339(lifetime_to_expiration(LifeTime)),
    ?assertMatch(
        {ok, #{
            <<"token">> := _,
            <<"validUntil">> := ValidUntil
        }},
        issue_destination_grant_call_api(LifeTime, C)
    ).

-spec issue_destination_grant_expired(config()) -> _.
issue_destination_grant_expired(C) ->
    _ = issue_destination_grant_start_mocks(C),
    LifeTime = -1000,
    ?assertEqual(
        {error, {422, #{<<"message">> => <<"Invalid expiration: already expired">>}}},
        issue_destination_grant_call_api(LifeTime, C)
    ).

%%

-spec create_withdrawal_with_both_grants(config()) -> _.
create_withdrawal_with_both_grants(C) ->
    _ = create_withdrawal_start_mocks(C),
    {ok, _} = create_withdrawal_call_api(C).

%%

-spec call_api(function(), map(), wapi_client_lib:context()) -> {ok, term()} | {error, term()}.
call_api(F, Params, Context) ->
    {Url, PreparedParams, Opts} = wapi_client_lib:make_request(Context, Params),
    Response = F(Url, PreparedParams, Opts),
    wapi_client_lib:handle_response(Response).

issue_destination_grant_call_api(Lifetime, C) ->
    call_api(
        fun swag_client_wallet_withdrawals_api:issue_destination_grant/3,
        #{
            binding => #{
                <<"destinationID">> => ?STRING
            },
            body => genlib_map:compact(#{
                <<"validUntil">> => posix_to_rfc3339(lifetime_to_expiration(Lifetime))
            })
        },
        wapi_ct_helper:cfg(context, C)
    ).

issue_wallet_grant_call_api(Lifetime, C) ->
    issue_wallet_grant_call_api(?INTEGER, Lifetime, C).

issue_wallet_grant_call_api(AssetAmount, Lifetime, C) ->
    call_api(
        fun swag_client_wallet_wallets_api:issue_wallet_grant/3,
        #{
            binding => #{
                <<"walletID">> => ?STRING
            },
            body => genlib_map:compact(#{
                <<"asset">> => #{
                    <<"amount">> => AssetAmount,
                    <<"currency">> => ?RUB
                },
                <<"validUntil">> => posix_to_rfc3339(lifetime_to_expiration(Lifetime))
            })
        },
        wapi_ct_helper:cfg(context, C)
    ).

create_withdrawal_call_api(C) ->
    {DestinationGrant, _} = ?config(destination_grant, C),
    {WalletGrant, _} = ?config(wallet_grant, C),
    call_api(
        fun swag_client_wallet_withdrawals_api:create_withdrawal/3,
        #{
            body => genlib_map:compact(#{
                <<"wallet">> => ?STRING,
                <<"destination">> => ?STRING,
                <<"body">> => #{
                    <<"amount">> => ?INTEGER,
                    <<"currency">> => ?RUB
                },
                <<"destinationGrant">> => DestinationGrant,
                <<"walletGrant">> => WalletGrant
            })
        },
        wapi_ct_helper:cfg(context, C)
    ).

%%

lifetime_to_expiration(Lt) when is_integer(Lt) ->
    genlib_time:unow() + Lt.

posix_to_rfc3339(Timestamp) when is_integer(Timestamp) ->
    genlib_rfc3339:format(Timestamp, second);
posix_to_rfc3339(unlimited) ->
    undefined.

%%

issue_destination_grant_start_mocks(C) ->
    PartyID = ?config(party, C),
    _ = wapi_ct_helper_bouncer:mock_assert_destination_op_ctx(<<"IssueDestinationGrant">>, ?STRING, PartyID, C),
    wapi_ct_helper:mock_services(
        [
            {fistful_destination, fun
                ('GetContext', _) -> {ok, ?DEFAULT_CONTEXT(PartyID)};
                ('Get', _) -> {ok, ?DESTINATION(PartyID)}
            end}
        ],
        C
    ).

issue_wallet_grant_start_mocks(C) ->
    PartyID = ?config(party, C),
    _ = wapi_ct_helper_bouncer:mock_assert_wallet_op_ctx(<<"IssueWalletGrant">>, ?STRING, PartyID, C),
    wapi_ct_helper:mock_services(
        [
            {fistful_wallet, fun
                ('GetContext', _) -> {ok, ?DEFAULT_CONTEXT(PartyID)};
                ('Get', _) -> {ok, ?WALLET(PartyID)}
            end}
        ],
        C
    ).

create_withdrawal_start_mocks(C) ->
    PartyID = ?config(granting_party, C),
    {_, DestinationExpiresAt} = ?config(destination_grant, C),
    {_, WalletExpiresAt} = ?config(wallet_grant, C),
    _ = wapi_ct_helper_bouncer:mock_assert_generic_op_ctx(
        [
            {destination, undefined, undefined},
            {wallet, undefined, undefined}
        ],
        ?CTX_WAPI(
            #bctx_v1_WalletAPIOperation{
                id = <<"CreateWithdrawal">>,
                destination = ?STRING,
                wallet = ?STRING
            },
            [
                ?CTX_WAPI_GRANT_DESTINATION(?STRING, DestinationExpiresAt),
                ?CTX_WAPI_GRANT_WALLET(?STRING, ?CTX_CASH(?INTEGER_BINARY, ?RUB), WalletExpiresAt)
            ]
        ),
        C
    ),
    wapi_ct_helper:mock_services(
        [
            {bender_thrift, fun('GenerateID', _) -> {ok, ?GENERATE_ID_RESULT} end},
            {fistful_wallet, fun
                ('Get', _) -> {ok, ?WALLET(PartyID)};
                ('GetContext', _) -> {ok, ?DEFAULT_CONTEXT(PartyID)}
            end},
            {fistful_destination, fun
                ('Get', _) -> {ok, ?DESTINATION(PartyID)};
                ('GetContext', _) -> {ok, ?DEFAULT_CONTEXT(PartyID)}
            end},
            {fistful_withdrawal, fun('Create', _) -> ?WITHDRAWAL(PartyID) end}
        ],
        C
    ).

%%

issue_wallet_and_destination_grant(C) ->
    LifeTime = 1000,
    DestinationGrant = issue_destination_grant_w_mock(LifeTime, C),
    WalletGrant = issue_wallet_grant_w_mock(LifeTime, C),
    {WalletGrant, DestinationGrant}.

issue_wallet_grant_w_mock(LifeTime, C0) ->
    C1 = [{test_sup, wapi_ct_helper:start_mocked_service_sup(?MODULE)} | C0],
    _ = issue_wallet_grant_start_mocks(C1),
    {ok, #{<<"token">> := Token, <<"validUntil">> := ExpiresAt}} = issue_wallet_grant_call_api(LifeTime, C1),
    _ = wapi_ct_helper:stop_mocked_service_sup(?config(test_sup, C1)),
    {Token, ExpiresAt}.

issue_destination_grant_w_mock(LifeTime, C0) ->
    C1 = [{test_sup, wapi_ct_helper:start_mocked_service_sup(?MODULE)} | C0],
    _ = issue_destination_grant_start_mocks(C1),
    {ok, #{<<"token">> := Token, <<"validUntil">> := ExpiresAt}} = issue_destination_grant_call_api(LifeTime, C1),
    _ = wapi_ct_helper:stop_mocked_service_sup(?config(test_sup, C1)),
    {Token, ExpiresAt}.
