defmodule AvmLs do
  @moduledoc """
  `AvmLs` - Atom VM LED Strip Examples
  """

  @doc """
  Start the application, callback for AtomVM init.
  """
  @spec start() :: :ok

  def start() do
    strip_len = 60
    start_args = %{di_pin: 32, strip_type: :ws2812, strip_len: strip_len}
    {_, _pid} = :avm_ls_server.start_link(start_args)

    colour = {:rgbi, {0, 220, 0, 15}}
    :avm_ls_server.fill(colour)

    Process.sleep(:infinity)
  end
end
