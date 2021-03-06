% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License.  You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the
% License for the specific language governing permissions and limitations under
% the License.

-module(couch_doc).

-export([to_doc_info/1,to_doc_info_path/1]).
-export([bin_foldl/3,bin_size/1,bin_to_binary/1,get_validate_doc_fun/1]).
-export([from_json_obj/1,to_json_obj/2,has_stubs/1, merge_stubs/2]).

-include("couch_db.hrl").

to_json_obj(#doc{id=Id,deleted=Del,body=Body,revs=Revs,meta=Meta}=Doc,Options)->
    {[{<<"_id">>, Id}] ++
        case Revs of
        [] -> [];
        _ -> [{<<"_rev">>, lists:nth(1, Revs)}]
        end ++
        case Del of
        false ->
            {BodyProps} = Body,
            BodyProps;
        true ->
            [{<<"_deleted">>, true}]
        end ++
        case lists:member(revs, Options) of
        false -> [];
        true ->
            [{<<"_revs">>, Revs}]
        end ++
        lists:map(
            fun({revs_info, RevsInfo}) ->
                JsonRevsInfo =
                [{[{rev, Rev}, {status, list_to_binary(atom_to_list(Status))}]} ||
                    {Rev, Status} <- RevsInfo],
                {<<"_revs_info">>, JsonRevsInfo};
            ({conflicts, Conflicts}) ->
                {<<"_conflicts">>, Conflicts};
            ({deleted_conflicts, Conflicts}) ->
                {<<"_deleted_conflicts">>, Conflicts}
            end, Meta) ++
        case lists:member(attachments, Options) of
        true -> % return the full rev list and the binaries as strings.
            BinProps = lists:map(
                fun({Name, {Type, BinValue}}) ->
                    {Name, {[
                        {<<"content_type">>, Type},
                        {<<"data">>, couch_util:encodeBase64(bin_to_binary(BinValue))}
                    ]}}
                end,
                Doc#doc.attachments),
            case BinProps of
            [] -> [];
            _ -> [{<<"_attachments">>, {BinProps}}]
            end;
        false ->
            BinProps = lists:map(
                fun({Name, {Type, BinValue}}) ->
                    {Name, {[
                        {<<"stub">>, true},
                        {<<"content_type">>, Type},
                        {<<"length">>, bin_size(BinValue)}
                    ]}}
                end,
                Doc#doc.attachments),
            case BinProps of
                [] -> [];
                _ -> [{<<"_attachments">>, {BinProps}}]
            end
        end
        }.

from_json_obj({Props}) ->
    {JsonBins} = proplists:get_value(<<"_attachments">>, Props, {[]}),
    Bins = lists:flatmap(fun({Name, {BinProps}}) ->
        case proplists:get_value(<<"stub">>, BinProps) of
        true ->
            [{Name, stub}];
        _ ->
            Value = proplists:get_value(<<"data">>, BinProps),
            Type = proplists:get_value(<<"content_type">>, BinProps,
                    ?DEFAULT_ATTACHMENT_CONTENT_TYPE),
            [{Name, {Type, couch_util:decodeBase64(Value)}}]
        end
    end, JsonBins),
    AllowedSpecialMembers = [<<"id">>, <<"revs">>, <<"rev">>, <<"attachments">>, <<"revs_info">>,
        <<"conflicts">>, <<"deleted_conflicts">>, <<"deleted">>],
    % collect all the doc-members that start with "_"
    % if any aren't in the AllowedSpecialMembers list 
    % then throw a doc_validation error
    [case lists:member(Name, AllowedSpecialMembers) of
        true ->
            ok;
        false ->
            throw({doc_validation, io_lib:format("Bad special document member: _~s", [Name])})
        end
         || {<<$_,Name/binary>>, _Value} <- Props],
    Revs =
    case proplists:get_value(<<"_revs">>, Props, []) of
    [] ->
        case proplists:get_value(<<"_rev">>, Props) of
        undefined -> [];
        Rev -> [Rev]
        end;
    Revs0 ->
        Revs0
    end,
    case proplists:get_value(<<"_id">>, Props, <<>>) of
    Id when is_binary(Id) -> ok;
    Id ->
        ?LOG_DEBUG("Document id is not a string: ~p", [Id]),
        throw({invalid_document_id, "Document id is not a string"})
    end,
    
    % strip out the all props beginning with _
    NewBody = {[{K, V} || {<<First,_/binary>>=K, V} <- Props, First /= $_]},
    #doc{
        id = Id,
        revs = Revs,
        deleted = proplists:get_value(<<"_deleted">>, Props, false),
        body = NewBody,
        attachments = Bins
        }.

to_doc_info(FullDocInfo) ->
    {DocInfo, _Path} = to_doc_info_path(FullDocInfo),
    DocInfo.

to_doc_info_path(#full_doc_info{id=Id,update_seq=Seq,rev_tree=Tree}) ->
    LeafRevs = couch_key_tree:get_all_leafs(Tree),
    SortedLeafRevs =
    lists:sort(fun({RevIdA, {IsDeletedA, _}, PathA}, {RevIdB, {IsDeletedB, _}, PathB}) ->
            % sort descending by {not deleted, then Depth, then RevisionId}
            A = {not IsDeletedA, length(PathA), RevIdA},
            B = {not IsDeletedB, length(PathB), RevIdB},
            A > B
        end,
        LeafRevs),

    [{RevId, {IsDeleted, SummaryPointer}, Path} | Rest] = SortedLeafRevs,

    {ConflictRevTuples, DeletedConflictRevTuples} =
        lists:splitwith(fun({_ConflictRevId, {IsDeleted1, _Sp}, _}) ->
                not IsDeleted1
            end, Rest),

    ConflictRevs = [RevId1  || {RevId1, _, _} <- ConflictRevTuples],
    DeletedConflictRevs = [RevId2   || {RevId2, _, _} <- DeletedConflictRevTuples],
    DocInfo = #doc_info{
        id=Id,
        update_seq=Seq,
        rev = RevId,
        summary_pointer = SummaryPointer,
        conflict_revs = ConflictRevs,
        deleted_conflict_revs = DeletedConflictRevs,
        deleted = IsDeleted},
    {DocInfo, Path}.

bin_foldl(Bin, Fun, Acc) when is_binary(Bin) ->
    case Fun(Bin, Acc) of
        {ok, Acc2} -> {ok, Acc2};
        {done, Acc2} -> {ok, Acc2}
    end;
bin_foldl({Fd, Sp, Len}, Fun, Acc) ->
    {ok, Acc2, _Sp2} = couch_stream:foldl(Fd, Sp, Len, Fun, Acc),
    {ok, Acc2}.

bin_size(Bin) when is_binary(Bin) ->
    size(Bin);
bin_size({_Fd, _Sp, Len}) ->
    Len.

bin_to_binary(Bin) when is_binary(Bin) ->
    Bin;
bin_to_binary({Fd, Sp, Len}) ->
    {ok, Bin, _Sp2} = couch_stream:read(Fd, Sp, Len),
    Bin.

get_validate_doc_fun(#doc{body={Props}}) ->
    Lang = proplists:get_value(<<"language">>, Props, <<"javascript">>),
    case proplists:get_value(<<"validate_doc_update">>, Props) of
    undefined ->
        nil;
    FunSrc ->
        fun(EditDoc, DiskDoc, Ctx) ->
            couch_query_servers:validate_doc_update(
                    Lang, FunSrc, EditDoc, DiskDoc, Ctx)
        end
    end.
        

has_stubs(#doc{attachments=Bins}) ->
    has_stubs(Bins);
has_stubs([]) ->
    false;
has_stubs([{_Name, stub}|_]) ->
    true;
has_stubs([_Bin|Rest]) ->
    has_stubs(Rest).

merge_stubs(#doc{attachments=MemBins}=StubsDoc, #doc{attachments=DiskBins}) ->
    BinDict = dict:from_list(DiskBins),
    MergedBins = lists:map(
        fun({Name, stub}) ->
            {Name, dict:fetch(Name, BinDict)};
        ({Name, Value}) ->
            {Name, Value}
        end, MemBins),
    StubsDoc#doc{attachments= MergedBins}.
