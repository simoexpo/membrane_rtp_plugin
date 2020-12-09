defmodule Membrane.SRTP.Decryptor do
  @moduledoc """
  Converts SRTP packets to plain RTP.

  Requires adding [srtp](https://github.com/membraneframework/elixir_libsrtp) dependency to work.
  """
  use Membrane.Filter

  require Membrane.Logger

  alias Membrane.Buffer

  def_input_pad :input, caps: :any, demand_unit: :buffers
  def_output_pad :output, caps: :any

  def_options policies: [
                spec: [ExLibSRTP.Policy.t()],
                description: """
                List of SRTP policies to use for decrypting packets.
                See `t:ExLibSRTP.Policy.t/0` for details.
                """
              ]

  @impl true
  def handle_init(options) do
    {:ok, Map.from_struct(options) |> Map.merge(%{srtp: nil})}
  end

  @impl true
  def handle_stopped_to_prepared(_ctx, state) do
    srtp = ExLibSRTP.new()

    state.policies
    |> Bunch.listify()
    |> Enum.each(&ExLibSRTP.add_stream(srtp, &1))

    {:ok, %{state | srtp: srtp}}
  end

  @impl true
  def handle_prepared_to_stopped(_ctx, state) do
    {:ok, %{state | srtp: nil}}
  end

  @impl true
  def handle_event(_pad, %{handshake_data: handshake_data}, _ctx, state) do
    {_client_keying_material, server_keying_material, protection_profile} = handshake_data

    {:ok, crypto_profile} =
      ExLibSRTP.Policy.crypto_profile_from_dtls_srtp_protection_profile(protection_profile)

    policy = %ExLibSRTP.Policy{
      ssrc: :any_inbound,
      key: server_keying_material,
      rtp: crypto_profile,
      rtcp: crypto_profile
    }

    :ok = ExLibSRTP.update(state.srtp, policy)
    {:ok, state}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  @impl true
  def handle_process(:input, buffer, _ctx, state) do
    case ExLibSRTP.unprotect(state.srtp, buffer.payload) do
      {:ok, payload} ->
        {{:ok, buffer: {:output, %Buffer{buffer | payload: payload}}}, state}

      {:error, reason} ->
        Membrane.Logger.warn("""
        Couldn't unprotect payload:
        #{inspect(buffer.payload, limit: :infinity)}
        Reason: #{inspect(reason)}. Ignoring packet.
        """)
    end
  end
end
