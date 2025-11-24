defmodule AvmLs do
  @moduledoc """
  `AvmLs` - Atom VM LED Strip walk.

  Walking leds with random colour and speed. Tested with ESP32-C3 SoC.
  """

  @doc """
  Start the application, callback for AtomVM init.
  Calls a loop that spawns one process for each led to walk the strip.
  Lasts for 6000 seconds.
  """
  @spec start() :: :ok

  def start() do
    strip_len = 60
    start_args = %{di_pin: 32, strip_type: :ws2812, strip_len: strip_len}
    {_, _pid} = :avm_ls_server.start_link(start_args)

    spawn(fn ->
      breath_loop({0, 200, 80},
        min_i: 16,
        max_i: 82,
        cycle_ms: 2000,
        step_ms: 8
      )
    end)

    # spawn(fn ->
    #   for i <- 1..strip_len do
    #     # IO.puts("Setting #{i} to Red")
    #     :avm_ls_server.set_led(i, color)
    #   end
    # end)

    # receive do after 500 -> :ok end
    # # :io.format(~c"Hello from Erlang!~n")
    # light_led(1, 2000, {10,20,30})
    # ## :timer.sleep(4000)
    # ## strip_len = 39
    # # duration = 500
    # # Process.spawn(fn -> walking_led(strip_len, duration, {10,10,0}) end,[])
    # loop(strip_len, 30)
    # # :timer.sleep(50000)
    # # :io.format(~c"Goodbye World!~n")
    Process.sleep(:infinity)

    :ok
  end

  @max_tick_multiplier 4
  @min_brightness_step 1
  @lowpass_alpha 0.35
  @instrument? false
  @brightness_curve (fn ->
                       steps = 128
                       gamma = 0.8

                       Enum.map(0..(steps - 1), fn i ->
                         fraction = i / (steps - 1)
                         wave = 0.5 - 0.5 * :math.cos(fraction * 2 * :math.pi())
                         :math.pow(wave, gamma)
                       end)
                       |> List.to_tuple()
                     end).()

  defp breath_loop({r, g, b}, opts) do
    min_i = opts |> Keyword.get(:min_i, 5) |> clamp_brightness()
    max_i = opts |> Keyword.get(:max_i, 100) |> max(min_i + 1)
    step_ms = opts |> Keyword.get(:step_ms, 15) |> max(5)
    cycle_ms = opts |> Keyword.get(:cycle_ms, 1600) |> max(step_ms)

    amplitude = max(max_i - min_i, 1)
    capped_max = min(min_i + amplitude, 100)
    debug? = Keyword.get(opts, :debug, false)
    log_event(:config, [min_i, capped_max, step_ms, cycle_ms])

    do_breath_phase(
      {r, g, b},
      min_i,
      capped_max,
      amplitude,
      step_ms,
      cycle_ms,
      0.0,
      nil,
      :none,
      nil,
      nil,
      debug?
    )
  end

  defp do_breath_phase(
         color,
         min_i,
         max_i,
         amplitude,
         step_ms,
         cycle_ms,
         phase_fraction,
         last_tick,
         last_extreme,
         last_brightness,
         last_sent_brightness,
         debug?
       ) do
    now = log_timestamp()
    elapsed =
      case last_tick do
        nil -> step_ms
        previous -> max(now - previous, step_ms)
      end

    clamped_elapsed = min(elapsed, step_ms * @max_tick_multiplier)
    {phase, next_fraction} = advance_phase(phase_fraction, clamped_elapsed, cycle_ms)

    {brightness, curve_value, raw_brightness} =
      lookup_brightness(min_i, max_i, amplitude, next_fraction)

    smoothed_brightness = apply_lowpass(brightness, last_sent_brightness)

    next_extreme = maybe_log_extreme(brightness, min_i, max_i, last_extreme)

    next_brightness =
      maybe_log_progress(brightness, last_brightness, phase, curve_value, raw_brightness)

    maybe_debug_phase(debug?, phase, curve_value, brightness, raw_brightness, min_i, max_i)
    fill_start = monotonic_microseconds()
    {fill_result, sent_brightness} =
      maybe_update_strip_color(color, smoothed_brightness, last_sent_brightness)
    fill_end = monotonic_microseconds()

    case fill_result do
      :updated -> log_instrument(:fill_us, fill_end - fill_start)
      :skipped -> :ok
    end

    next_sent_brightness =
      case fill_result do
        :updated -> sent_brightness
        :skipped -> last_sent_brightness
      end

    Process.sleep(step_ms)
    sleep_end = monotonic_microseconds()
    log_instrument(:sleep_us, sleep_end - fill_end)

    do_breath_phase(
      color,
      min_i,
      max_i,
      amplitude,
      step_ms,
      cycle_ms,
      next_fraction,
      now,
      next_extreme,
      next_brightness,
      next_sent_brightness,
      debug?
    )
  end


  defp advance_phase(fraction, delta_ms, cycle_ms) do
    delta_fraction = delta_ms / cycle_ms
    updated_fraction = fraction + delta_fraction
    wrapped = updated_fraction - :math.floor(updated_fraction)
    phase = round(wrapped * 255)
    {phase, wrapped}
  end

  defp log_instrument(tag, value) do
    if @instrument? do
      :erlang.display({:instrument, monotonic_microseconds(), tag, value})
    else
      :ok
    end
  end

  defp monotonic_microseconds do
    :erlang.monotonic_time(:microsecond)
  end

  defp apply_lowpass(value, nil), do: value

  defp apply_lowpass(value, last) when value == last, do: value

  defp apply_lowpass(value, last) do
    delta = value - last
    adjustment =
      delta * @lowpass_alpha
      |> :erlang.round()
      |> ensure_min_step(delta)

    clamp_brightness(last + adjustment)
  end

  defp ensure_min_step(value, delta) when value == 0.0 and delta > 0, do: 1
  defp ensure_min_step(value, delta) when value == 0.0 and delta < 0, do: -1
  defp ensure_min_step(value, _delta) when value == 0.0, do: 0
  defp ensure_min_step(value, _delta), do: trunc(value)

  defp set_strip_color({r, g, b}, brightness) do
    colour = {:rgbi, {r, g, b, clamp_brightness(brightness)}}
    :avm_ls_server.fill_async(colour)
  end

  defp maybe_update_strip_color(color, brightness, nil) do
    set_strip_color(color, brightness)
    {:updated, brightness}
  end

  defp maybe_update_strip_color(_color, brightness, brightness), do: {:skipped, brightness}

  defp maybe_update_strip_color(color, brightness, last) do
    if abs(brightness - last) >= @min_brightness_step do
      set_strip_color(color, brightness)
      {:updated, brightness}
    else
      {:skipped, last}
    end
  end

  defp lookup_brightness(min_i, max_i, amplitude, phase_fraction) do
    eased = lookup_curve_value(phase_fraction)
    scaled = round(eased * amplitude)
    raw_brightness = min_i + scaled
    brightness = clamp_brightness(min(raw_brightness, max_i))
    display_value = round(eased * 255)
    {brightness, display_value, raw_brightness}
  end

  defp lookup_curve_value(fraction) do
    steps = tuple_size(@brightness_curve)
    scaled = fraction * (steps - 1)
    base = trunc(:math.floor(scaled))
    rem = scaled - base
    next = min(base + 1, steps - 1)
    lower = :erlang.element(base + 1, @brightness_curve)
    upper = :erlang.element(next + 1, @brightness_curve)
    lower + (upper - lower) * rem
  end


  defp maybe_log_extreme(brightness, min_i, max_i, last_extreme) do
    cond do
      brightness <= min_i + 1 and last_extreme != :min ->
        log_breath(:valley, brightness)
        :min

      brightness >= max_i - 1 and last_extreme != :max ->
        log_breath(:peak, brightness)
        :max

      brightness >= min_i + 4 and brightness <= max_i - 4 ->
        :none

      true ->
        last_extreme
    end
  end


  defp log_breath(tag, brightness) do
    log_event(tag, [brightness])
  end

  defp maybe_log_progress(brightness, nil, phase, curve_value, raw) do
    log_breath_detail(:start, brightness, phase, curve_value, raw)
    brightness
  end

  defp maybe_log_progress(brightness, last, phase, curve_value, raw) do
    cond do
      abs(brightness - last) >= 10 ->
        log_breath_detail(:progress, brightness, phase, curve_value, raw)

      rem(phase, 64) == 0 ->
        log_breath_detail(:phase_checkpoint, brightness, phase, curve_value, raw)

      true ->
        :ok
    end

    brightness
  end

  defp log_breath_detail(tag, brightness, phase, curve_value, raw) do
    log_event(tag, [brightness, phase, curve_value, raw])
  end

  defp maybe_debug_phase(false, _phase, _curve_value, _brightness, _raw, _min_i, _max_i),
    do: :ok

  defp maybe_debug_phase(true, phase, curve_value, brightness, raw, min_i, max_i) do
    cond do
      phase < 16 ->
        log_event(:phase, [phase, curve_value, brightness, raw])

      rem(phase, 16) == 0 ->
        log_event(:phase_sample, [phase, curve_value, brightness, raw])

      curve_value == 0 and rem(phase, 32) == 0 ->
        log_event(:flat, [phase, curve_value, brightness, raw])

      brightness == min_i and rem(phase, 64) == 0 ->
        log_event(:stuck_low, [phase])

      brightness == max_i and rem(phase, 64) == 0 ->
        log_event(:at_peak, [phase])

      true ->
        :ok
    end
  end

  @log_breath false

  defp log_event(tag, payload) do
    if @log_breath do
      message = [:breath, log_timestamp(), tag | payload] |> List.to_tuple()
      :erlang.display(message)
    else
      :ok
    end
  end

  defp log_timestamp, do: :erlang.monotonic_time(:millisecond)

  defp clamp_brightness(value) when value <= 0, do: 0
  defp clamp_brightness(value) when value >= 100, do: 100
  defp clamp_brightness(value), do: value

  # defp loop(_strip_len, 0) do
  #   :ok
  # end
  # defp loop(strip_len, n) do
  #   rand = :avm_ls_server.random()
  #   << duration::8, r::8, g::8, b::8 >> = << rand :: 32 >>
  #   duration = duration + 200
  #   b = div(b, 2)
  #   if (r + g) > 512 do
  #     Process.spawn(fn -> walking_led(strip_len, duration, {r, g, b}) end,[])
  #   else
  #     Process.spawn(fn -> walking_led_up(strip_len, duration, {r,g,b}) end, [])
  #   end
  #   receive do after 3000 -> :ok end
  #   loop(strip_len, n-1)
  # end

  # defp light_led(index, duration, {r,g,b}) do
  #   :avm_ls_server.set_led(index,{:rgb,{r,g,b}})
  #   :timer.sleep(duration)
  #   :avm_ls_server.clear_led(index)
  # end

  # defp walking_led(0, _, _) do
  #   :ok
  # end
  # defp walking_led(n, duration, {_r,_g,_b} = c) do
  #   light_led(n, duration, c)
  #   walking_led(n-1, duration, c)
  # end

  # defp walking_led_up(n, duration, {r,g,b}) do
  #   walking_led_up(n+1, 1, duration, {r,g,b})
  # end

  # defp walking_led_up(stop, stop, _, _) do
  #   :ok
  # end
  # defp walking_led_up(stop, n, duration, {_r,_g,_b} = c) do
  #   light_led(n, duration, c)
  #   walking_led_up(stop, n+1, duration, c)
  # end
end
