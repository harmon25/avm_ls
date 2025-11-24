%
%
% Copyright 2024 Mikael Karlsson <mikael.karlsson@creado.se>
%
% Licensed under the Apache License, Version 2.0 (the "License");
% you may not use this file except in compliance with the License.
% You may obtain a copy of the License at
%
%    http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS,
% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
% See the License for the specific language governing permissions and
% limitations under the License.
%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%
% Many Espressif ESP32 Devkit boards have an RGB LED of type "LED strip"
% See also: https://components.espressif.com/components/espressif/led_strip

-module(avm_ls_server).
-moduledoc """
The LED Strip gen_server module.

""".
-behaviour(gen_server).

%% API
-export([start_link/1, set_led/2, clear_led/1, fill/1, fill_async/1, random/0]).

%%% gen_server callbacks
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).

-define(MOD_PRE_FIX, "avm_ls_").
-define(SERVER, ?MODULE).
-type col() :: 0..255.
-type white() :: 0..255.
-type ill() :: 0..100.

-doc "Different ways of setting the LED color, white channel, and illumination".
-type colours() :: {rgb, {col(), col(), col()}} |
                   {rgbi, {col(), col(), col(), ill()}} |
                   {rgbw, {col(), col(), col(), white()}} |
                   {rgbwi, {col(), col(), col(), white(), ill()}} |
                   {hsv, {0..360, 0..100, ill()}}.

-type led_components() :: #{r := non_neg_integer(),
                           g := non_neg_integer(),
                           b := non_neg_integer(),
                           w := non_neg_integer(),
                           i := non_neg_integer()}.

-type strip_type() :: avm_ls_strip:strip_type().
-type strip_len() :: non_neg_integer().

-type start_args() :: #{
                        strip_len := strip_len(),
                        strip_type := strip_type(),
                        di_pin := non_neg_integer(),
                        ci_pin => non_neg_integer()
                        }.

-type state() :: #{ led_array := map(),
                    spi := pid(),
                    strip_len := strip_len(),
                    strip_index := non_neg_integer(),
                    device_name := strip_type(),
                    cbm := module(),
                    flush_pending := boolean()
                  }.

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------
-doc "Starts the server".
-spec start_link(Args :: start_args()) -> {ok, Pid :: pid()} |
          {error, Error :: {already_started, pid()}} |
          {error, Error :: term()} |
          ignore.
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Args, []).


-doc "Set the spedific LED colour. Index starts at 1".
-spec set_led(Index::pos_integer(), Colours::colours()) ->
          ok | {error, index_too_large}| no_return().
set_led(Index, {rgb, {_R, _G, _B}} = C)      -> set_led1(Index, C);
set_led(Index, {rgbi, {_R, _G, _B, _I}} = C) -> set_led1(Index, C);
set_led(Index, {rgbw, {_R, _G, _B, _W}} = C) -> set_led1(Index, C);
set_led(Index, {rgbwi, {_R, _G, _B, _W, _I}} = C) -> set_led1(Index, C);
set_led(Index, {hsv, {_H, _S, _V}} = C)      -> set_led1(Index, C).

set_led1(Index, C) ->
    gen_server:cast(?SERVER, {set_led, {Index, C}, self()}).

-doc "Clear the spedific LED.".
-spec clear_led(Index::pos_integer()) -> ok | {error, index_too_large} | no_return().
clear_led(Index) ->
    gen_server:cast(?SERVER, {clear_led, Index, self()}).

-doc "Set all LEDs to the same colour synchronously".
-spec fill(Colours::colours()) -> ok.
fill(Colours) ->
    gen_server:call(?SERVER, {fill, Colours}).

-doc "Set all LEDs to the same colour asynchronously".
-spec fill_async(Colours::colours()) -> ok.
fill_async(Colours) ->
    gen_server:cast(?SERVER, {fill_async, Colours, self()}),
    ok.

random() -> atomvm:random().

-spec init(Args::start_args()) -> state().
init(Args) ->
    io:format("Args2 ~p~n",[Args]),
    process_flag(trap_exit, true),
    StripLen = maps:get(strip_len, Args, 1),
    StripType = maps:get(strip_type, Args, ws2812),
    StripTypeStr = atom_to_binary(StripType, utf8),
    CallBackMod = binary_to_atom(<< ?MOD_PRE_FIX, StripTypeStr/binary >>, utf8),
    SPIConfigPars = #{
                      di_pin => maps:get(di_pin, Args),
                      ci_pin => maps:get(ci_pin, Args, -1),
                      name => StripType
                     },
    SPIConfig = CallBackMod:spi_config(SPIConfigPars),
    SPI = spi:open(SPIConfig),
    %% ARR = maps:from_keys(lists:seq(1, StripLen), #{self() => {rgbi,{0,0,0,0}}}),
    ARR = maps:from_keys(lists:seq(1, StripLen), #{}),
        State =
                #{led_array => ARR,
                    spi => SPI,
                    strip_len => StripLen,
                    strip_index => StripLen,
                    cbm => CallBackMod,
                    device_name => StripType,
                    flush_pending => false
                 },
        {ok, State}.


%%% gen_server callbacks
-spec handle_call(Request :: term(), From :: gen_server:from(),
                      State :: term()) ->
    {reply, Reply :: term(), NewState :: term()}.
handle_call({set_led, {Index, Colours}}, {Pid, _Tag},
            #{led_array := Arr, strip_len := Len, strip_index := SI} = State) ->
    if
        Index >= 1,
        Index =< Len ->
            link(Pid),
            NewArr = update_array(Index, Arr, Pid, Colours),
            NewState0 = State#{led_array := NewArr, strip_index := max(Index, SI)},
            NewState = maybe_trigger_flush(NewState0),
            {reply, ok, NewState};
        true ->
            {reply, {error, index_too_large}, State}
    end;
handle_call({clear_led, Index}, {Pid, _Tag},
            #{led_array := Arr, strip_len := Len, strip_index := SI} = State) ->
    if
        Index >= 1,
        Index =< Len ->
            {NewArr, Removed} = remove_pid_from_array(Index, Pid, Arr),
            maybe_unlink_pid(Removed, Pid, NewArr),
            NewState0 = State#{led_array := NewArr, strip_index := max(Index, SI)},
            NewState = maybe_trigger_flush(NewState0),
            {reply, ok, NewState};
        true ->
            {reply, {error, index_too_large}, State}
    end;
handle_call({fill, Colour}, {Pid, _Tag}, State) ->
    link(Pid),
    NewState = apply_fill(State, Colour, Pid),
    {reply, ok, NewState};
handle_call(_, _, _) ->
    error(not_implemented).

-spec handle_cast(Request :: term(), State :: term()) ->
    {noreply, NewState :: term()} |
    {noreply, NewState :: term(), timeout() | hibernate | {continue, term()}} |
    {stop, Reason :: term(), NewState :: term()}.
handle_cast({set_led, {Index, Colours}, Pid},
            #{led_array := Arr, strip_len := Len, strip_index := SI} = State) ->
    if
        Index >= 1,
        Index =< Len ->
            link(Pid),
            NewArr = update_array(Index, Arr, Pid, Colours),
            NewState0 = State#{led_array := NewArr, strip_index := max(Index, SI)},
            NewState = maybe_trigger_flush(NewState0),
            {noreply, NewState};
        true ->
            {noreply, State}
    end;
handle_cast({clear_led, Index, Pid},
            #{led_array := Arr, strip_len := Len, strip_index := SI} = State) ->
    if
        Index >= 1,
        Index =< Len ->
            {NewArr, Removed} = remove_pid_from_array(Index, Pid, Arr),
            maybe_unlink_pid(Removed, Pid, NewArr),
            NewState0 = State#{led_array := NewArr, strip_index := max(Index, SI)},
            NewState = maybe_trigger_flush(NewState0),
            {noreply, NewState};
        true ->
            {noreply, State}
    end;
handle_cast({fill, Colour, Pid},
        State) ->
    link(Pid),
    NewState = apply_fill(State, Colour, Pid),
    {noreply, NewState};
handle_cast({fill_async, Colour, Pid},
        #{flush_pending := true} = State) ->
    unlink(Pid),
    {noreply, State};
handle_cast({fill_async, Colour, Pid},
        State) ->
    link(Pid),
    NewState = apply_fill(State, Colour, Pid),
    {noreply, NewState};
handle_cast(_, _) ->
  error(not_implemented).

-spec handle_info(Info :: timeout | term(), State :: term()) ->
    {noreply, NewState :: term()} |
    {noreply, NewState :: term(), timeout() | hibernate | {continue, term()}} |
    {stop, Reason :: term(), NewState :: term()}.

handle_info({'EXIT', Pid, _Reason}, #{led_array := Arr, strip_index := SI} = State) ->
    {LastIndex, NewArr} =
        maps:fold(
          fun(Index, M, {I, ArrAcc}) ->
                  case is_map_key(Pid, M) of
                      true ->
                          {max(Index,I), maps:put(Index, maps:remove(Pid, M), ArrAcc)};
                      false ->
                          {I, ArrAcc}
                  end
          end, {0, Arr}, Arr),
    {noreply, State#{led_array := NewArr, strip_index := max(LastIndex, SI)}};
handle_info(update_led_strip, State) ->
    NewState = update_led_strip(State),
    {noreply, NewState}.

-spec terminate(Reason :: (normal | shutdown | {shutdown, term()} |
                               term()),
                    State :: term()) ->
    term().
terminate(_Reason, #{spi := SPI}) ->
    spi:close(SPI).


%% Private functions

update_array(Index, Array, Pid, Value) ->
    Map = maps:get(Index, Array),
    NewMap = Map#{Pid => Value},
    maps:put(Index, NewMap, Array).

apply_fill(#{strip_len := Len} = State, Value, Pid) ->
    NewArr = fill_array(Len, Pid, Value),
    NewState0 = State#{led_array := NewArr, strip_index := Len},
    maybe_trigger_flush(NewState0).

fill_array(Len, Pid, Value) ->
        lists:foldl(
            fun(Index, Acc) ->
                            maps:put(Index, #{Pid => Value}, Acc)
            end, #{}, lists:seq(1, Len)).

remove_pid_from_array(Index, Pid, Array) ->
    Map = maps:get(Index, Array),
    case maps:is_key(Pid, Map) of
        true ->
            NewMap = maps:remove(Pid, Map),
            {maps:put(Index, NewMap, Array), true};
        false ->
            {Array, false}
    end.

maybe_unlink_pid(true, Pid, Array) ->
    case pid_present(Pid, Array) of
        true -> ok;
        false -> unlink(Pid)
    end;
maybe_unlink_pid(false, _Pid, _Array) ->
    ok.

pid_present(Pid, Array) ->
    maps:fold(fun(_Index, Map, Acc) ->
                      Acc orelse maps:is_key(Pid, Map)
              end, false, Array).

maybe_trigger_flush(State = #{strip_index := SI, flush_pending := false}) when SI > 0 ->
    erlang:send(self(), update_led_strip),
    State#{flush_pending := true};
maybe_trigger_flush(State) ->
    State.

update_led_strip(#{led_array := Arr, cbm := CBM, spi := SPI,
                   strip_index := SI, device_name := Name} = State)
  when SI > 0 ->
    Dirty = collect_dirty_leds(Arr, SI),
    case Dirty of
        [] ->
            State#{strip_index := 0, flush_pending := false};
        _ ->
            Values = [format_led_value(Name, V) || {_, V} <- lists:sort(Dirty)],
            WriteData = CBM:build_stream(Values),
            ok = spi:write(SPI, Name, #{write_data => WriteData}),
            State#{strip_index := 0, flush_pending := false}
    end;
update_led_strip(State) ->
    State#{flush_pending := false}.

collect_dirty_leds(Arr, MaxIndex) ->
    maps:fold(fun(Index, Map, Acc) when Index > 0, Index =< MaxIndex ->
                      Sum = sum_led_entries(Map),
                      [{Index, clamp_components(Sum)} | Acc];
                 (_, _, Acc) ->
                      Acc
              end, [], Arr).

-spec sum_led_entries(map()) -> led_components().
sum_led_entries(Map) ->
    maps:fold(fun(_Pid, V, Acc) -> sum_components(V, Acc) end,
              empty_components(), Map).

empty_components() ->
    #{r => 0, g => 0, b => 0, w => 0, i => 0}.

-spec clamp_components(led_components()) -> led_components().
clamp_components(#{r := R, g := G, b := B, w := W, i := I} = Components) ->
    Components#{r := min(R, 255),
                g := min(G, 255),
                b := min(B, 255),
                w := min(W, 255),
                i := min(I, 100)}.

sum_components({rgb, {R, G, B}}, Acc) ->
    Acc#{r := maps:get(r, Acc) + R,
         g := maps:get(g, Acc) + G,
         b := maps:get(b, Acc) + B};
sum_components({rgbi, {R, G, B, I}}, Acc) ->
    add_brightness(sum_components({rgb, {R, G, B}}, Acc), I);
sum_components({rgbw, {R, G, B, W}}, Acc) ->
    add_white(sum_components({rgb, {R, G, B}}, Acc), W);
sum_components({rgbwi, {R, G, B, W, I}}, Acc) ->
    add_brightness(sum_components({rgbw, {R, G, B, W}}, Acc), I);
sum_components({hsv, {H, S, V}}, Acc) ->
    {R, G, B} = write_dot_hsv({H, S, V}),
    add_brightness(sum_components({rgb, {R, G, B}}, Acc), V);
sum_components(_, Acc) ->
    Acc.

add_brightness(Acc, Value) ->
    Acc#{i := maps:get(i, Acc) + Value}.

add_white(Acc, Value) ->
    Acc#{w := maps:get(w, Acc) + Value}.

format_led_value(sk6812, #{r := R, g := G, b := B, w := W}) ->
    {R, G, B, W};
format_led_value(_, #{r := R, g := G, b := B, i := I}) ->
    {R, G, B, I}.


write_dot_hsv({H, S, V}) ->
    RGB_max = (V * 255) div 100,
    RGB_min = (RGB_max * (100 - S)) div 100,
    Diff = H rem 60,
    RGB_adj = ((RGB_max - RGB_min) * Diff) div 60,
    Sextant = H div 60,
    case Sextant of
        0 -> {RGB_max, RGB_min + RGB_adj, RGB_min};
        1 -> {RGB_max - RGB_adj, RGB_max, RGB_min};
        2 -> {RGB_min, RGB_max, RGB_min + RGB_adj};
        3 -> {RGB_min, RGB_max - RGB_adj, RGB_max};
        4 -> {RGB_min + RGB_adj, RGB_min, RGB_max};
        _ -> {RGB_max, RGB_min, RGB_max - RGB_adj}
    end.
