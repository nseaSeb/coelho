if Code.ensure_loaded?(Kino.JS.Live) and Code.ensure_loaded?(Phoenix.Component) do
  defmodule Coelho.Kino do
    @moduledoc """
    A Coelho editor in a Livebook cell.

        editor = Coelho.Kino.new()

    It is the same editor a LiveView renders — the same component, the same
    hook, the same schema on both sides — so what a notebook shows is what an
    application gets. Read what was typed, as the document that would be
    stored:

        Coelho.Kino.read(editor)

    React to every change:

        Kino.listen(editor, fn %{type: :change, document: document} ->
          IO.inspect(Coelho.to_text(document))
        end)

    Every change is validated on the server before it is kept, exactly as a
    form submission would be: a document the schema refuses is never stored,
    and the editor that sent it is put back to the last valid one.

    Requires `kino` and `phoenix_live_view`, both optional dependencies of
    Coelho:

        Mix.install([:coelho, :kino, :phoenix_live_view])

    The editor has no uploads: a LiveView's upload channel is what carries
    them, and a notebook has none.

    ## One writer at a time

    Each change carries the whole document, and the last one to arrive is
    what is kept. Two people typing in the same editor — two tabs on one
    session, or a collaborator in Livebook — overwrite each other, and the
    other editors are not told of a change until they reconnect. Writing
    together is collaboration proper, which Coelho does not do yet.
    """

    use Kino.JS, assets_path: "priv/static", entrypoint: "kino.js"
    use Kino.JS.Live

    alias Coelho.{Document, Schema}

    @typedoc "An event emitted to `Kino.listen/2` and `Kino.Control.stream/1`."
    @type event ::
            %{type: :change, document: map()}
            | %{type: :hook, event: String.t(), payload: term()}

    @doc """
    A new editor.

    ## Options

      * `:schema` — the `Coelho.Schema` to edit under. `Coelho.Schema.default/0`
        when omitted
      * `:value` — the document to start from, validated against the schema;
        an empty document when omitted

    Any other option is an attribute of `Coelho.LiveView.coelho_editor/1` —
    `:toolbar`, `:labels`, `:placeholder`, `:maxlength` — passed through as
    given. `:suggest` passes through too, but only opens and closes the list:
    the queries arrive as `:hook` events, and nothing here inserts a choice.

    Raises `ArgumentError` for a `:value` the schema refuses.
    """
    @spec new(keyword()) :: Kino.JS.Live.t()
    def new(opts \\ []) do
      schema = Keyword.get(opts, :schema, Schema.default())

      document =
        case Keyword.fetch(opts, :value) do
          {:ok, value} -> validate!(value, schema)
          :error -> Coelho.empty(schema)
        end

      editor = Keyword.drop(opts, [:schema, :value])

      Kino.JS.Live.new(__MODULE__, {schema, document, editor})
    end

    @doc """
    The document in the editor, as it would be stored.
    """
    @spec read(Kino.JS.Live.t()) :: map()
    def read(kino), do: Kino.JS.Live.call(kino, :read)

    @doc """
    Replaces the document in the editor.

    Validated like everything else: `{:error, errors}` leaves the editor as it
    was.
    """
    @spec set(Kino.JS.Live.t(), map()) :: :ok | {:error, [Document.Error.t()]}
    def set(kino, document), do: Kino.JS.Live.call(kino, {:set, document})

    @impl true
    def init({schema, document, editor}, ctx) do
      id = "coelho-kino-" <> Integer.to_string(System.unique_integer([:positive]))

      {:ok, assign(ctx, schema: schema, document: document, editor: editor, id: id, version: 0)}
    end

    @impl true
    def handle_connect(ctx),
      do: {:ok, %{html: html(ctx), version: ctx.assigns.version}, ctx}

    @impl true
    # A change made on a document set/2 has since replaced: a keystroke in
    # flight when the replacement went out. Taking it would undo the
    # replacement here while the editor shows it.
    def handle_event("change", %{"version" => version}, ctx)
        when version != ctx.assigns.version,
        do: {:noreply, ctx}

    def handle_event("change", %{"value" => value}, ctx) when is_binary(value) do
      case decode(value, ctx.assigns.schema) do
        {:ok, document} when document == ctx.assigns.document ->
          {:noreply, ctx}

        {:ok, document} ->
          emit_event(ctx, %{type: :change, document: document})
          {:noreply, assign(ctx, document: document)}

        # What the browser sent is input like any other. Refused, the editor
        # that sent it is put back to the document the server holds, so the
        # writer sees what will be kept rather than what was typed.
        :error ->
          send_event(ctx, ctx.origin, "set", set_payload(ctx))
          {:noreply, ctx}
      end
    end

    # What the hook asks of a LiveView — a suggestion list opened or closed —
    # handed on to whoever listens, untouched.
    def handle_event("hook", %{"event" => event, "payload" => payload}, ctx)
        when is_binary(event) do
      emit_event(ctx, %{type: :hook, event: event, payload: payload})
      {:noreply, ctx}
    end

    def handle_event(_event, _payload, ctx), do: {:noreply, ctx}

    @impl true
    def handle_call(:read, _from, ctx), do: {:reply, ctx.assigns.document, ctx}

    def handle_call({:set, value}, _from, ctx) do
      case Document.validate(value, ctx.assigns.schema) do
        {:ok, document} ->
          ctx = assign(ctx, document: document, version: ctx.assigns.version + 1)
          broadcast_event(ctx, "set", set_payload(ctx))
          emit_event(ctx, %{type: :change, document: document})
          {:reply, :ok, ctx}

        {:error, errors} ->
          {:reply, {:error, errors}, ctx}
      end
    end

    defp set_payload(ctx),
      do: %{value: JSON.encode!(ctx.assigns.document), version: ctx.assigns.version}

    defp decode(value, schema) do
      with {:ok, decoded} <- JSON.decode(value),
           {:ok, document} <- Document.validate(decoded, schema) do
        {:ok, document}
      else
        _refused -> :error
      end
    end

    defp validate!(value, schema) do
      case Document.validate(value, schema) do
        {:ok, document} ->
          document

        {:error, errors} ->
          raise ArgumentError,
                "the :value is not a document this schema accepts: " <>
                  Enum.map_join(errors, "; ", &Document.Error.format/1)
      end
    end

    defp html(ctx) do
      %{
        __changed__: nil,
        id: ctx.assigns.id,
        name: "document",
        value: ctx.assigns.document,
        document_schema: ctx.assigns.schema
      }
      |> Map.merge(Map.new(ctx.assigns.editor))
      |> Coelho.LiveView.coelho_editor()
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()
    end
  end
end
