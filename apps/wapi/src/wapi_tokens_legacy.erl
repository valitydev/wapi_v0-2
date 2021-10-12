-module(wapi_tokens_legacy).

-export([issue_grant/2]).
-export([verify_grant/2]).

-export([get_verification_options/0]).
-export([get_resource_hierarchy/0]).
-export([get_access_config/0]).
-export([get_signee/0]).

-type token_spec() :: {destination, destination_grant()} | {wallet, wallet_grant()}.

-type destination_grant() :: #{
    destination := resource_id(),
    expires_on := expires_on()
}.

-type wallet_grant() :: #{
    wallet := resource_id(),
    body => wallet_grant_asset(),
    expires_on := expires_on()
}.

-type wallet_grant_asset() :: #{
    amount => binary(),
    currency => binary()
}.

-type resource_id() :: binary().
-type token() :: uac_authorizer_jwt:token().
-type expires_on() :: binary().

-define(DOMAIN, <<"wallet-api">>).

-define(GRANT_RESOURCE_ACL(ResourceName, ResourceID), {[party, {ResourceName, ResourceID}], [write]}).

%%

-spec issue_grant(wapi_handler_utils:owner(), token_spec()) -> token().
issue_grant(PartyID, TokenSpec) ->
    Claims = encode_grant_claims(TokenSpec),
    wapi_utils:unwrap(
        uac_authorizer_jwt:issue(
            wapi_utils:get_unique_id(),
            PartyID,
            Claims,
            get_signee()
        )
    ).

-spec verify_grant
    (wallet, token()) -> wallet_grant() | no_return();
    (destination, token()) -> destination_grant() | no_return().
verify_grant(Resource, Token) ->
    case uac_authorizer_jwt:verify(Token, get_verification_options()) of
        {ok, {_, _, Claims, _}} ->
            decode_grant_claims({Resource, Claims});
        {error, Reason} ->
            throw({token_verification_failed, Reason})
    end.

%%

encode_grant_claims(
    {destination, #{
        destination := DestinationID,
        expires_on := Expiration
    }}
) ->
    #{
        <<"exp">> => genlib_rfc3339:parse(Expiration, second),
        <<"resource_access">> => encode_grant_resource_access(destination, DestinationID)
    };
encode_grant_claims(
    {wallet,
        #{
            wallet := WalletID,
            expires_on := Expiration
        } = Wallet}
) ->
    Body = maybe_encode_wallet_body(Wallet),
    maps:merge(
        #{
            <<"exp">> => genlib_rfc3339:parse(Expiration, second),
            <<"resource_access">> => encode_grant_resource_access(wallet, WalletID)
        },
        Body
    ).

maybe_encode_wallet_body(#{body := Body}) ->
    encode_wallet_body(Body);
maybe_encode_wallet_body(_) ->
    #{}.

encode_wallet_body(Body) ->
    genlib_map:compact(#{
        <<"amount">> => maps:get(amount, Body, undefined),
        <<"currency">> => maps:get(currency, Body, undefined)
    }).

encode_grant_resource_access(Resource, ResourceID) ->
    #{
        ?DOMAIN => uac_acl:from_list(
            [{[party, {get_acl_resource_name(Resource), ResourceID}], write}]
        )
    }.

%%

decode_grant_claims({destination = Resource, Claims}) ->
    #{
        destination => decode_grant_resource_access(Resource, Claims),
        expires_on => genlib_rfc3339:format(maps:get(<<"exp">>, Claims), second)
    };
decode_grant_claims({wallet = Resource, Claims}) ->
    Body = maybe_decode_wallet_body(Claims),
    maps:merge(
        #{
            wallet => decode_grant_resource_access(Resource, Claims),
            expires_on => genlib_rfc3339:format(maps:get(<<"exp">>, Claims), second)
        },
        Body
    ).

maybe_decode_wallet_body(Claims) ->
    case decode_wallet_body(Claims) of
        Body when map_size(Body) > 0 ->
            #{body => Body};
        _ ->
            #{}
    end.

decode_wallet_body(Claims) ->
    genlib_map:compact(#{
        amount => maps:get(<<"amount">>, Claims, undefined),
        currency => maps:get(<<"currency">>, Claims, undefined)
    }).

decode_grant_resource_access(Resource, Claims) ->
    ACLResource = get_acl_resource_name(Resource),
    case get_acl(Claims) of
        {ok, [?GRANT_RESOURCE_ACL(ACLResource, ResourceID)]} ->
            ResourceID;
        {ok, ACL} ->
            throw({acl_mismatch, ACL});
        {error, Reason} ->
            throw({acl_decode_failed, Reason})
    end.

%%

get_acl_resource_name(wallet) ->
    wallets;
get_acl_resource_name(destination) ->
    destinations.

get_acl(#{<<"resource_access">> := #{?DOMAIN := #{<<"roles">> := Roles}}}) ->
    decode_acl(Roles);
% Legacy grants support
get_acl(#{<<"resource_access">> := #{<<"common-api">> := #{<<"roles">> := Roles}}}) ->
    decode_acl(Roles);
get_acl(_) ->
    {error, missing}.

decode_acl(Roles) ->
    try
        {ok, uac_acl:to_list(uac_acl:decode(Roles))}
    catch
        error:Reason -> {error, {invalid, Reason}}
    end.

-spec get_access_config() -> map().
get_access_config() ->
    #{
        domain_name => ?DOMAIN,
        resource_hierarchy => get_resource_hierarchy()
    }.

-spec get_resource_hierarchy() -> #{atom() => map()}.
%% TODO put some sense in here
% This resource hierarchy refers to wallet api actaully
get_resource_hierarchy() ->
    #{
        party => #{
            wallets => #{},
            destinations => #{}
        },
        w2w => #{},
        webhooks => #{},
        withdrawals => #{withdrawal_quotes => #{}}
    }.

-spec get_verification_options() -> uac:verification_opts().
get_verification_options() ->
    #{}.

-spec get_signee() -> term().
get_signee() ->
    wapi_utils:unwrap(application:get_env(wapi, signee)).

% -ifdef(TEST).
% -include_lib("eunit/include/eunit.hrl").

% -spec test() -> _.

% -spec extract_rights_test() -> _.

% extract_rights_test() ->
%     _ = ets:new(uac_conf, [set, public, named_table, {read_concurrency, true}]),
%     ok = uac:configure(#{jwt => #{}, access => get_access_config()}),
%     WalletGrant = #{wallet => <<"1">>, expires_on => <<"0">>},
%     Claims = encode_grant_claims({wallet, WalletGrant}),
%     ?assertEqual(WalletGrant, decode_grant_claims({wallet, Claims})).

% -endif.
