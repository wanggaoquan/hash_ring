%% @copyright 2013 Takeru Ohta <phjgt308@gmail.com>
%%
%% @doc 静的に構築されたコンシステントハッシュリングを操作するためのモジュール
-module(hash_ring_static).

-behaviour(hash_ring).

%%--------------------------------------------------------------------------------
%% Exported API
%%--------------------------------------------------------------------------------
-export([
         make/2,
         get_nodes/1,
         fold/4
        ]).

-export_type([
              ring/0,
              option/0
             ]).

%%--------------------------------------------------------------------------------
%% Macros & Recors & Types
%%--------------------------------------------------------------------------------
-define(RING, ?MODULE).
-define(DEFAULT_VIRTUAL_NODE_COUNT, 1024). % 各ノードごとの仮想ノードの数
-define(DEFAULT_MAX_HASH_BYTE_SIZE, 4).
-define(DEFAULT_HASH_ALGORITHM, md5).

-record(?RING,
        {
          virtual_node_hashes :: tuple(),
          virtual_nodes       :: tuple(),
          nodes               :: [hash_ring:ring_node()],
          hash_mask           :: integer(),
          hash_algorithm      :: hash_ring:hash_algorithms()
        }).

-opaque ring() :: #?RING{}.

-type option() :: {virtual_node_count, pos_integer()}
                | {max_hash_byte_size, pos_integer()}
                | {hash_algorithm, hash_ring:hash_algorithms()}.

%%--------------------------------------------------------------------------------
%% Exported Functions
%%--------------------------------------------------------------------------------
%% @doc コンシステントハッシュリングを構築する
-spec make([hash_ring:ring_node()], [option()]) -> ring().
make(Nodes, Options) ->
    VirtualNodeCount = proplists:get_value(virtual_node_count, Options, ?DEFAULT_VIRTUAL_NODE_COUNT),
    HashAlgorithm    = proplists:get_value(hash_algorithm, Options, ?DEFAULT_HASH_ALGORITHM),
    MaxHashByteSize0 = proplists:get_value(max_hash_byte_size, Options, ?DEFAULT_MAX_HASH_BYTE_SIZE),
    MaxHashByteSize  = min(MaxHashByteSize0, hash_ring_util:hash_byte_size(HashAlgorithm)),

    HashMask = (1 bsl MaxHashByteSize * 8) - 1,
    
    VirtualNodes1 = lists:append([[begin 
                                       VirtualNodeHash = hash_ring_util:calc_hash(HashAlgorithm, {I, Node}) band HashMask,
                                       {VirtualNodeHash, Node}
                                   end || I <- lists:seq(1, VirtualNodeCount)] || Node <- Nodes]),
    VirtualNodes2 = lists:sort(VirtualNodes1), % lists:keysort/2 だとハッシュ値に衝突がある場合に、順番が一意に定まらないので単なる sort/1 を使用する
    #?RING{
        virtual_node_hashes = erlang:append_element(list_to_tuple([Hash || {Hash, _} <- VirtualNodes2]), HashMask + 1), % append sentinel value
        virtual_nodes       = list_to_tuple([Node || {_, Node} <- VirtualNodes2]),
        nodes               = lists:usort(Nodes),
        hash_mask           = HashMask,
        hash_algorithm      = HashAlgorithm
       }.

%% @doc ノード一覧を取得する
-spec get_nodes(ring()) -> [hash_ring:ring_node()].
get_nodes(Ring) ->
    Ring#?RING.nodes.

%% @doc アイテムの次に位置するノードから順に畳み込みを行う
-spec fold(hash_ring:fold_fun(), hash_ring:item(), term(), ring()) -> Result::term().
fold(Fun, Item, Initial, Ring) ->
    #?RING{hash_algorithm = HashAlgorithm, hash_mask = HashMask, nodes = Nodes,
           virtual_nodes = VirtualNodes, virtual_node_hashes = VirtualNodeHashes} = Ring,
    ItemHash = hash_ring_util:calc_hash(HashAlgorithm, Item) band HashMask,
    PartitionSize = max(1, (HashMask  + 1) div tuple_size(VirtualNodeHashes)),
    Position = find_start_position(ItemHash, PartitionSize, VirtualNodeHashes),
    fold_successor_nodes(length(Nodes), Position, VirtualNodes, Fun, Initial).

%%--------------------------------------------------------------------------------
%% Internal Functions
%%--------------------------------------------------------------------------------
-spec find_start_position(term(), pos_integer(), tuple()) -> non_neg_integer().
find_start_position(ItemHash, PartitionSize, VirtualNodeHashes) ->
    find_start_position(ItemHash, PartitionSize, VirtualNodeHashes, 1, (ItemHash div PartitionSize) + 1, tuple_size(VirtualNodeHashes) + 1).

-spec find_start_position(term(), pos_integer(), tuple(), pos_integer(), pos_integer(), pos_integer()) -> pos_integer().
find_start_position(_ItemHash, _PartitionSize, _VirtualNodeHashes, Position, _, Position) ->
    Position;
find_start_position(ItemHash, PartitionSize, VirtualNodeHashes, Start, Current0, End) ->
    Current  = min(max(Start, Current0), End - 1),
    NodeHash = element(Current, VirtualNodeHashes),
    case NodeHash of
        ItemHash -> Current;
        _        ->
            Delta = ItemHash - NodeHash,
            Next  = Current + (Delta div PartitionSize),
            case Delta > 0 of
                true  -> find_start_position(ItemHash, PartitionSize, VirtualNodeHashes, Current + 1, Next + 1, End);
                false -> find_start_position(ItemHash, PartitionSize, VirtualNodeHashes, Start, Next - 1, Current)
            end                    
    end.

-spec fold_successor_nodes(non_neg_integer(), non_neg_integer(), tuple(), hash_ring:fold_fun(), term()) -> term().
fold_successor_nodes(RestNodeCount, StartPosition, VirtualNodes, Fun, Initial) ->
    fold_successor_nodes(RestNodeCount, StartPosition, VirtualNodes, Fun, Initial, []).

-spec fold_successor_nodes(non_neg_integer(), non_neg_integer(), tuple(), hash_ring:fold_fun(), term(), [hash_ring:ring_node()]) -> term().
fold_successor_nodes(0, _, _, _, Acc, _) ->
    Acc;
fold_successor_nodes(RestNodeCount, Position, VirtualNodes, Fun, Acc, IteratedNodes) when Position > tuple_size(VirtualNodes) ->
    fold_successor_nodes(RestNodeCount, 1, VirtualNodes, Fun, Acc, IteratedNodes);
fold_successor_nodes(RestNodeCount, Position, VirtualNodes, Fun, Acc, IteratedNodes) ->
    Node = element(Position, VirtualNodes),
    case lists:member(Node, IteratedNodes) of % NOTE: ノード数が多くなるとスケールしない
        true  -> fold_successor_nodes(RestNodeCount, Position + 1, VirtualNodes, Fun, Acc, IteratedNodes);
        false ->
            case Fun(Node, Acc) of
                {false, Acc2} -> Acc2;
                {true,  Acc2} -> fold_successor_nodes(RestNodeCount - 1, Position + 1, VirtualNodes, Fun, Acc2, [Node | IteratedNodes])
            end
    end.
