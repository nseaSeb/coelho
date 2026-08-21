defmodule Coelho.Telemetry do
  @moduledoc """
  The events Coelho emits, and what they carry.

  Three spans, each `:start` / `:stop` / `:exception` in the usual shape, so
  `:telemetry.attach_many/4` and `Telemetry.Metrics` work on them without
  anything special:

  | Event | When | Metadata |
  | --- | --- | --- |
  | `[:coelho, :validate, _]` | `Coelho.Document.validate/2` | `:schema`, and on `:stop` `:result` (`:ok`/`:error`), `:errors`, `:nodes`, `:text_length` |
  | `[:coelho, :render, _]` | `Coelho.Render.to_iodata/3` | `:schema`, and on `:stop` `:bytes` |
  | `[:coelho, :storage, _]` | `Coelho.Storage.put/3` | `:storage`, `:key`, and on `:stop` `:result` |

  `:schema` is `Coelho.Schema.fingerprint/1` rather than the struct — a
  schema is a few kilobytes of specs and parse rules, and putting it in the
  metadata of every keystroke's validation would hand every handler a copy.
  It is settled when the schema is built, so reading it costs nothing.

  ## What it costs

  Nothing at all in a build without `:telemetry`: the metadata and the
  measurements are functions, and neither is called. With `:telemetry`
  present the metadata is built whether or not a handler is attached, so it
  is kept to what is already known — `:nodes` and `:text_length` are counted
  by the bounds check validation runs anyway, not by a walk of their own.

  ## Attaching

      :telemetry.attach_many(
        "coelho",
        [[:coelho, :validate, :stop], [:coelho, :render, :stop]],
        &MyApp.Telemetry.handle/4,
        nil
      )

  Validation runs on every keystroke of every editor, so a handler on it is
  on a hot path — count and summarise there, do not log.

  ## Without `:telemetry`

  The dependency is optional and Coelho works without it: the spans compile
  down to calling the function, and nothing is emitted. Nothing to configure
  either way.
  """

  # Resolved where Coelho is compiled, which is the consuming application —
  # so an application that does not carry :telemetry pays nothing at all, not
  # even a runtime check.
  @enabled Code.ensure_loaded?(:telemetry)

  @doc """
  Whether events are being emitted at all.
  """
  # The answer is decided when this compiles, so in any given build only one
  # of the two is reachable and Dialyzer says the spec has a type too many.
  # It is a boolean across builds, which is what the spec is for.
  @dialyzer {:nowarn_function, enabled?: 0}
  @spec enabled?() :: boolean()
  def enabled?, do: @enabled

  @doc """
  Runs `fun`, emitting a span around it.

  Both `metadata` and `measure` are *functions*, and neither is called in a
  build without `:telemetry`. Passing the metadata as a value would build it
  on every call whether or not anything was listening, which on a path that
  runs per keystroke is the measurement costing more than the work: this is
  the difference between an optional dependency and an optional cost.

  `measure` is handed the result and answers what to merge into the `:stop`
  event's metadata.
  """
  @spec span([atom()], (-> map()), (-> result), (result -> map())) :: result
        when result: term()
  if @enabled do
    def span(event, metadata, fun, measure) do
      metadata = metadata.()

      :telemetry.span(event, metadata, fn ->
        result = fun.()
        {result, Map.merge(metadata, measure.(result))}
      end)
    end
  else
    def span(_event, _metadata, fun, _measure), do: fun.()
  end
end
