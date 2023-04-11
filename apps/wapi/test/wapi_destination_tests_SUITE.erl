-module(wapi_destination_tests_SUITE).

-include_lib("stdlib/include/assert.hrl").
-include_lib("common_test/include/ct.hrl").

-include_lib("wapi_wallet_dummy_data.hrl").

-include_lib("fistful_proto/include/fistful_fistful_base_thrift.hrl").
-include_lib("fistful_proto/include/fistful_fistful_thrift.hrl").
-include_lib("fistful_proto/include/fistful_account_thrift.hrl").
-include_lib("fistful_proto/include/fistful_identity_thrift.hrl").
-include_lib("fistful_proto/include/fistful_destination_thrift.hrl").
-include_lib("tds_proto/include/tds_storage_thrift.hrl").

-export([all/0]).
-export([groups/0]).
-export([init_per_suite/1]).
-export([init_per_group/2]).
-export([end_per_group/2]).
-export([end_per_suite/1]).
-export([init_per_testcase/2]).
-export([end_per_testcase/2]).

-export([init/1]).

-export([create_destination_forbidden_test/1]).
-export([get_destination_fail_notfound_test/1]).
-export([create_extension_destination_ok_test/1]).
-export([create_extension_destination_fail_unknown_resource_test/1]).

-define(GENERIC_RESOURCE_TYPE, <<"BankTransferGeneric">>).
-define(GENERIC_RESOURCE_NAME, <<"GenericBankAccount">>).

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
            create_destination_forbidden_test,
            get_destination_fail_notfound_test,
            create_extension_destination_ok_test,
            create_extension_destination_fail_unknown_resource_test
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
    GroupSup = wapi_ct_helper:start_mocked_service_sup(?MODULE),
    _ = wapi_ct_helper_token_keeper:mock_user_session_token(Party, GroupSup),
    [{group_test_sup, GroupSup}, {context, wapi_ct_helper:get_context(?API_TOKEN)} | Config1];
init_per_group(_, Config) ->
    Config.

-spec end_per_group(group_name(), config()) -> _.
end_per_group(_Group, C) ->
    _ = wapi_ct_helper:stop_mocked_service_sup(?config(group_test_sup, C)),
    ok.

-spec init_per_testcase(test_case_name(), config()) -> config().
init_per_testcase(Name, C) when
    Name =:= create_extension_destination_ok_test orelse
        Name =:= create_extension_destination_fail_unknown_resource_test
->
    meck:new(swag_server_wallet_schema, [no_link, passthrough]),
    meck:new(swag_client_wallet_schema, [no_link, passthrough]),
    makeup_and_start_mock_per_testcase(Name, C);
init_per_testcase(Name, C) ->
    makeup_and_start_mock_per_testcase(Name, C).

-spec end_per_testcase(test_case_name(), config()) -> ok.
end_per_testcase(Name, C) when
    Name =:= create_extension_destination_ok_test orelse
        Name =:= create_extension_destination_fail_unknown_resource_test
->
    meck:unload(swag_server_wallet_schema),
    meck:unload(swag_client_wallet_schema),
    end_mock_per_testcase(C);
end_per_testcase(_Name, C) ->
    end_mock_per_testcase(C).

makeup_and_start_mock_per_testcase(Name, C) ->
    C1 = wapi_ct_helper:makeup_cfg([wapi_ct_helper:test_case_name(Name), wapi_ct_helper:woody_ctx()], C),
    [{test_sup, wapi_ct_helper:start_mocked_service_sup(?MODULE)} | C1].

end_mock_per_testcase(C) ->
    wapi_ct_helper:stop_mocked_service_sup(?config(test_sup, C)),
    ok.

%%% Tests

-spec create_destination_forbidden_test(config()) -> _.
create_destination_forbidden_test(C) ->
    Destination = make_destination(C, bank_card),
    PartyID = ?config(party, C),
    _ = wapi_ct_helper_bouncer:mock_arbiter(wapi_ct_helper_bouncer:judge_always_forbidden(), C),
    _ = wapi_ct_helper:mock_services(
        [
            {bender_thrift, fun('GenerateID', _) -> {ok, ?GENERATE_ID_RESULT} end},
            {fistful_identity, fun
                ('GetContext', _) -> {ok, ?DEFAULT_CONTEXT(PartyID)};
                ('Get', _) -> {ok, ?IDENTITY(PartyID)}
            end},
            {fistful_destination, fun('Create', _) -> Destination end}
        ],
        C
    ),
    ?assertMatch(
        {error, {401, #{}}},
        create_destination_call_api(C, Destination)
    ).

-spec get_destination_fail_notfound_test(config()) -> _.
get_destination_fail_notfound_test(C) ->
    _ = get_destination_start_mocks(C, {throwing, #fistful_DestinationNotFound{}}),
    _ = wapi_ct_helper_bouncer:mock_arbiter(wapi_ct_helper_bouncer:judge_always_forbidden(), C),
    ?assertEqual(
        {error, {404, #{}}},
        get_destination_call_api(C)
    ).

-spec create_extension_destination_ok_test(config()) -> _.
create_extension_destination_ok_test(C) ->
    Ref = <<"#/definitions/", ?GENERIC_RESOURCE_NAME/binary>>,
    ResourceSchema = #{
        <<"allOf">> =>
            [
                #{
                    <<"$ref">> => <<"#/definitions/DestinationResource">>
                },
                #{
                    <<"$ref">> => Ref
                }
            ],
        <<"x-vality-genericMethod">> =>
            #{
                <<"schema">> =>
                    #{
                        <<"id">> => <<"https://some.link">>,
                        <<"allOf">> =>
                            [
                                #{
                                    <<"$ref">> => Ref
                                }
                            ]
                    }
            }
    },
    mock_generic_schema(ResourceSchema),
    Destination = make_destination(C, generic),
    _ = create_destination_start_mocks(C, {ok, Destination}),
    ?assertMatch(
        {ok, _},
        create_destination_call_api(C, Destination)
    ).

-spec create_extension_destination_fail_unknown_resource_test(config()) -> _.
create_extension_destination_fail_unknown_resource_test(C) ->
    Ref = <<"#/definitions/", ?GENERIC_RESOURCE_NAME/binary>>,
    ResourceSchema = #{
        <<"allOf">> => [
            #{
                <<"$ref">> => <<"#/definitions/DestinationResource">>
            },
            #{
                <<"$ref">> => Ref
            }
        ]
    },
    mock_generic_schema(ResourceSchema),
    Destination = make_destination(C, generic),
    _ = create_destination_start_mocks(C, {ok, Destination}),
    ?assertMatch(
        {error,
            {400, #{
                <<"errorType">> := <<"SchemaViolated">>,
                <<"description">> := <<"Unknown resource">>
            }}},
        create_destination_call_api(C, Destination)
    ).

%%

-spec call_api(function(), map(), wapi_client_lib:context()) -> {ok, term()} | {error, term()}.
call_api(F, Params, Context) ->
    {Url, PreparedParams, Opts} = wapi_client_lib:make_request(Context, Params),
    Response = F(Url, PreparedParams, Opts),
    wapi_client_lib:handle_response(Response).

build_destination_spec(D, undefined) ->
    build_destination_spec(D, D#destination_DestinationState.resource);
build_destination_spec(D, Resource) ->
    #{
        <<"name">> => D#destination_DestinationState.name,
        <<"identity">> => (D#destination_DestinationState.account)#account_Account.identity,
        <<"currency">> =>
            D#destination_DestinationState.account#account_Account.currency#fistful_base_CurrencyRef.symbolic_code,
        <<"externalID">> => D#destination_DestinationState.external_id,
        <<"resource">> => build_resource_spec(Resource)
    }.

build_resource_spec({bank_card, R}) ->
    #{
        <<"type">> => <<"BankCardDestinationResource">>,
        <<"token">> => wapi_crypto:create_resource_token(
            {bank_card, R#fistful_base_ResourceBankCard.bank_card}, undefined
        )
    };
build_resource_spec(
    {generic, #fistful_base_ResourceGeneric{generic = #fistful_base_ResourceGenericData{data = Data}}}
) ->
    #fistful_base_Content{data = Params} = Data,
    jsx:decode(Params).

uniq() ->
    genlib:bsuuid().

generate_identity(PartyID) ->
    #identity_IdentityState{
        id = ?STRING,
        name = uniq(),
        party_id = PartyID,
        provider_id = uniq(),
        context = generate_context(PartyID)
    }.

generate_context(PartyID) ->
    #{
        ?CTX_NS =>
            {obj, #{
                {str, <<"owner">>} => {str, PartyID},
                {str, <<"name">>} => {str, uniq()},
                {str, <<"metadata">>} => {obj, #{{str, <<"key">>} => {str, <<"val">>}}}
            }}
    }.

generate_destination(IdentityID, Resource, Context) ->
    ID = ?STRING,
    #destination_DestinationState{
        id = ID,
        name = uniq(),
        status = {authorized, #destination_Authorized{}},
        account = #account_Account{
            id = ID,
            identity = IdentityID,
            currency = #fistful_base_CurrencyRef{
                symbolic_code = <<"RUB">>
            },
            accounter_account_id = 123
        },
        resource = Resource,
        external_id = ?STRING,
        created_at = <<"2016-03-22T06:12:27Z">>,
        blocking = unblocked,
        metadata = #{<<"key">> => {str, <<"val">>}},
        context = Context
    }.

generate_resource(bank_card) ->
    {bank_card, #fistful_base_ResourceBankCard{
        bank_card = #fistful_base_BankCard{
            token = uniq(),
            bin = <<"424242">>,
            masked_pan = <<"4242">>,
            bank_name = uniq(),
            payment_system = #fistful_base_PaymentSystemRef{id = <<"foo">>},
            issuer_country = rus,
            card_type = debit,
            exp_date = #fistful_base_BankCardExpDate{
                month = 12,
                year = 2200
            }
        }
    }};
generate_resource(generic) ->
    Data = jsx:encode(#{
        <<"type">> => ?GENERIC_RESOURCE_TYPE,
        <<"accountNumber">> => <<"1233123">>
    }),
    ID = <<"https://some.link">>,
    Type = <<"application/schema-instance+json; schema=", ID/binary>>,
    {generic, #fistful_base_ResourceGeneric{
        generic = #fistful_base_ResourceGenericData{
            data = #fistful_base_Content{type = Type, data = Data},
            provider = #fistful_base_PaymentServiceRef{id = ?GENERIC_RESOURCE_TYPE}
        }
    }}.

make_destination(C, ResourceType) ->
    PartyID = ?config(party, C),
    Identity = generate_identity(PartyID),
    Resource = generate_resource(ResourceType),
    Context = generate_context(PartyID),
    generate_destination(Identity#identity_IdentityState.id, Resource, Context).

create_destination_start_mocks(C, CreateDestinationResult) ->
    PartyID = ?config(party, C),

    _ = wapi_ct_helper_bouncer:mock_assert_identity_op_ctx(<<"CreateDestination">>, ?STRING, PartyID, C),
    wapi_ct_helper:mock_services(
        [
            {bender_thrift, fun('GenerateID', _) -> {ok, ?GENERATE_ID_RESULT} end},
            {fistful_identity, fun
                ('GetContext', _) -> {ok, ?DEFAULT_CONTEXT(PartyID)};
                ('Get', _) -> {ok, ?IDENTITY(PartyID)}
            end},
            {fistful_destination, fun('Create', _) -> CreateDestinationResult end}
        ],
        C
    ).

create_destination_call_api(C, Destination) ->
    create_destination_call_api(C, Destination, undefined).

create_destination_call_api(C, Destination, Resource) ->
    call_api(
        fun swag_client_wallet_withdrawals_api:create_destination/3,
        #{
            body => build_destination_spec(Destination, Resource)
        },
        wapi_ct_helper:cfg(context, C)
    ).

get_destination_start_mocks(C, GetDestinationResult) ->
    PartyID = ?config(party, C),
    wapi_ct_helper:mock_services(
        [
            {fistful_destination, fun
                ('GetContext', _) -> {ok, ?DEFAULT_CONTEXT(PartyID)};
                ('Get', _) -> GetDestinationResult
            end}
        ],
        C
    ).

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

mock_generic_schema(ResourceSchema) ->
    Raw = swag_server_wallet_schema:get(),
    Definitions = maps:get(<<"definitions">>, Raw),
    Get = fun() ->
        Raw#{
            <<"definitions">> => Definitions#{
                ?GENERIC_RESOURCE_TYPE => ResourceSchema,
                ?GENERIC_RESOURCE_NAME => #{
                    <<"type">> => <<"object">>,
                    <<"required">> => [<<"accountNumber">>],
                    <<"properties">> => #{
                        <<"accountNumber">> => #{
                            <<"type">> => <<"string">>,
                            <<"example">> => <<"0071717">>,
                            <<"pattern">> => <<"^\\d{7,8}$">>
                        }
                    }
                },
                <<"DestinationResource">> => #{
                    <<"type">> => <<"object">>,
                    <<"required">> => [<<"type">>],
                    <<"discriminator">> => <<"type">>,
                    <<"properties">> => #{
                        <<"type">> => #{
                            <<"type">> => <<"string">>,
                            <<"enum">> => [?GENERIC_RESOURCE_TYPE]
                        }
                    }
                }
            }
        }
    end,
    meck:expect(swag_server_wallet_schema, get, Get),
    meck:expect(swag_client_wallet_schema, get, Get).
