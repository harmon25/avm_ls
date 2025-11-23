-module(avm_ls_sk6812).
-moduledoc """
SK6812 RGBW (NeoPixel-compatible) callback module.
Implements `avm_ls_strip` behaviour.
""".

-behaviour(avm_ls_strip).
-export([spi_config/1,
         build_stream/1]).

-doc "SK6812 uses a single data pin like WS2812. Clock derived from SPI at 2.4 MHz".
-spec spi_config(avm_ls_strip:spi_conf()) -> list().
spi_config(#{di_pin := DiPin, name := DeviceName}) when is_integer(DiPin) ->
    [
     {bus_config,
      [
       {miso, -1},       %% Not used
       {mosi, DiPin},
       {sclk, -1}        %% Not used
      ]},
     {device_config,
      [
       {DeviceName,
        [
         {clock_speed_hz, 2400000}, %% 3 SPI bits per LED bit ~ 1.25 uS
         {mode, 0},
         {cs, -1}, %% Not used
         {address_len_bits, 8}
        ]}
      ]}
    ].

-spec build_stream([{avm_ls_server:col(), avm_ls_server:col(), avm_ls_server:col(),
                     avm_ls_server:white()}]) -> binary().
build_stream(RGBWList) ->
    build_stream(RGBWList, fun({R, G, B, W}) -> {G, R, B, W} end).

build_stream(RGBWList, OrderFun) ->
    build_stream(RGBWList, OrderFun, []).
build_stream([{R, G, B, W}|T], OrderFun, Acc) ->
    LedN = led_strip_bytes(OrderFun({R, G, B, W})),
    build_stream(T, OrderFun, [LedN|Acc]);
build_stream([], _, Acc) ->
    list_to_binary(lists:reverse(Acc)).

%% 1 RGBW LED will be 96 SPI bits <=> 12 bytes
led_strip_bytes({C1, C2, C3, C4}) ->
    CB1 = led_strip_bits(C1),
    CB2 = led_strip_bits(C2),
    CB3 = led_strip_bits(C3),
    CB4 = led_strip_bits(C4),
    << CB1:24, CB2:24, CB3:24, CB4:24 >>.

%% SK6812 LED SPI encoding matches WS2812 timings
led_strip_bits(A) when A >= 0, A < 256, is_integer(A) ->
    led_strip_bits(A, 7, 0).

led_strip_bits(_A, N, Acc) when N < 0 -> Acc;
led_strip_bits(A, N, Acc) ->
    SPIbits =
        case (A bsr N) band 16#01 of
            1 -> 6; %% 110
            0 -> 4  %% 100
        end,
    led_strip_bits(A, N-1, (Acc bsl 3) bor SPIbits).
