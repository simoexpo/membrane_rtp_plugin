defmodule Membrane.RTP.Serializer do
  @moduledoc """
  Serializes RTP payload to RTP packets by adding the RTP header to each of them.

  Accepts the following metadata under `:rtp` key: `:marker`, `:csrcs`, `:extension`.
  See `Membrane.RTP.Header` for their meaning and specifications.
  """
  use Membrane.Filter

  alias Membrane.{Buffer, RTP, RemoteStream}

  @max_seq_num 65535
  @max_timestamp 0xFFFFFFFF

  def_input_pad :input, caps: RTP, demand_unit: :buffers
  def_output_pad :output, caps: {RemoteStream, type: :packetized, content_format: RTP}

  def_options ssrc: [spec: RTP.ssrc_t()],
              payload_type: [spec: RTP.payload_type_t()],
              clock_rate: [spec: RTP.clock_rate_t()],
              alignment: [
                default: 1,
                spec: pos_integer(),
                description: """
                Number of bytes that each packet should be aligned to.
                Alignment is achieved by adding RTP padding.
                """
              ]

  @impl true
  def handle_init(options) do
    state = %{
      sequence_number: Enum.random(0..@max_seq_num),
      init_timestamp: Enum.random(0..@max_timestamp)
    }

    {:ok, Map.merge(Map.from_struct(options), state)}
  end

  @impl true
  def handle_caps(:input, _caps, _ctx, state) do
    caps = %RemoteStream{type: :packetized, content_format: RTP}
    {{:ok, caps: {:output, caps}}, state}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  @impl true
  def handle_process(:input, %Buffer{payload: payload, metadata: metadata}, _ctx, state) do
    {rtp_metadata, metadata} = Map.pop(metadata, :rtp, %{})
    %{timestamp: timestamp} = metadata
    rtp_offset = timestamp |> Ratio.mult(state.clock_rate) |> Membrane.Time.to_seconds()
    rtp_timestamp = rem(state.init_timestamp + rtp_offset, @max_timestamp + 1)

    header = %RTP.Header{
      ssrc: state.ssrc,
      marker: Map.get(rtp_metadata, :marker, false),
      payload_type: state.payload_type,
      timestamp: rtp_timestamp,
      sequence_number: state.sequence_number,
      csrcs: Map.get(rtp_metadata, :csrcs, []),
      extension: Map.get(rtp_metadata, :extension)
    }

    packet = %RTP.Packet{header: header, payload: payload}
    payload = RTP.Packet.serialize(packet, align_to: state.alignment)
    buffer = %Buffer{payload: payload, metadata: metadata}
    state = Map.update!(state, :sequence_number, &rem(&1 + 1, @max_seq_num + 1))
    {{:ok, buffer: {:output, buffer}}, state}
  end
end