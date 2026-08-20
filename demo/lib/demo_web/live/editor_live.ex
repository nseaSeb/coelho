defmodule DemoWeb.EditorLive do
  @moduledoc """
  One document, four server-side derivations of it, live.

  The point of the demo is not the editor — that is ProseMirror, and everyone
  has seen one. It is everything to the right of it: the stored document, the
  HTML the server renders from it, the plain text it would index, and the
  validation errors, all recomputed on the server on every keystroke, from
  the same schema the browser is editing against.
  """

  use DemoWeb, :live_view

  import Coelho.LiveView

  defmodule Post do
    @moduledoc false
    use Ecto.Schema

    import Ecto.Changeset
    import Coelho.Ecto

    embedded_schema do
      field(:title, :string)
      rich_text(:body, document_schema: Demo.RichText.schema())
    end

    def changeset(post, attrs) do
      post
      |> cast(attrs, [:title, :body])
      |> validate_required([:title])
    end
  end

  @impl true
  def mount(_params, _session, socket) do
    post = %Post{title: "Coelho", body: sample_document()}

    {:ok,
     socket
     |> assign(:post, post)
     |> allow_upload(:attachment,
       accept: :any,
       max_entries: 1,
       max_file_size: 8_000_000,
       auto_upload: true,
       progress: &handle_progress/3
     )
     |> assign_document(post.body)
     |> assign(:errors, [])
     |> assign_form(Post.changeset(post, %{}))}
  end

  @impl true
  def handle_event("validate", %{"post" => params}, socket) do
    changeset = socket.assigns.post |> Post.changeset(params) |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign_document(Ecto.Changeset.get_field(changeset, :body))
     |> assign(:errors, document_errors(changeset))
     |> assign_form(changeset)}
  end

  def handle_event("mention", _params, socket) do
    # A node the application decides on, built server side against the same
    # schema that will validate it on the way back.
    {:noreply,
     insert_node(socket, %{
       "type" => "mention",
       "attrs" => %{"user_id" => 7, "label" => "@ada"}
     })}
  end

  def handle_event("save", %{"post" => params}, socket) do
    changeset = socket.assigns.post |> Post.changeset(params) |> Map.put(:action, :insert)

    if changeset.valid? do
      # There is nowhere to save to — the point is that the document reaching
      # this line is already validated and canonical.
      {:noreply,
       socket
       |> put_flash(:info, "Valid. The document above is exactly what would be written.")
       |> assign_form(changeset)}
    else
      {:noreply,
       socket
       |> assign(:errors, document_errors(changeset))
       |> assign_form(changeset)}
    end
  end

  # The upload channel is LiveView's; what to do with the bytes is the
  # application's. Coelho only wants the node to insert.
  defp handle_progress(:attachment, entry, socket) do
    if entry.done? do
      # The callback has to answer {:ok, term} or LiveView raises and takes the
      # process with it, so a storage failure is wrapped rather than returned.
      # consume_uploaded_entry/3 then hands back the term itself.
      result =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          {:ok, Demo.Uploads.store(path, entry.client_name, entry.client_type)}
        end)

      case result do
        {:ok, attachment} ->
          {:noreply,
           insert_node(socket, Coelho.Attachment.to_node(attachment),
             preview: Demo.Uploads.url(attachment.key)
           )}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Could not store the file: #{inspect(reason)}")}
      end
    else
      {:noreply, socket}
    end
  end

  defp assign_form(socket, changeset), do: assign(socket, :form, to_form(changeset, as: :post))

  # Rendering runs on every keystroke, so it runs once per change rather than
  # once per place the template shows it.
  defp assign_document(socket, document) do
    socket
    |> assign(:document, document)
    |> assign(:html, rendered_html(document))
    |> assign(:text, plain_text(document))
    |> assign(:json, stored_json(document))
  end

  # The Ecto type attaches the schema violations to the changeset error, so
  # showing them is a matter of reading them back out.
  defp document_errors(changeset) do
    case changeset.errors[:body] do
      {_message, opts} -> Keyword.get(opts, :errors, [])
      nil -> []
    end
  end

  # Attachment URLs are resolved on every render, never stored. The signature
  # below expires in five minutes, which is exactly what storing the URL in
  # the document would make impossible.
  defp attachment_url(key), do: Demo.Uploads.url(key)

  defp rendered_html(nil), do: ""

  defp rendered_html(document) do
    Coelho.to_html(document, Demo.RichText.schema(), context: %{resolve: &attachment_url/1})
  end

  defp plain_text(nil), do: ""
  defp plain_text(document), do: Coelho.to_text(document, Demo.RichText.schema())

  defp stored_json(nil), do: ""
  defp stored_json(document), do: JSON.encode!(document)

  defp sample_document do
    %{
      "type" => "doc",
      "content" => [
        %{
          "type" => "heading",
          "attrs" => %{"level" => 2},
          "content" => [%{"type" => "text", "text" => "The document is the storage"}]
        },
        %{
          "type" => "paragraph",
          "content" => [
            %{"type" => "text", "text" => "Type on the left. Everything on the right is "},
            %{
              "type" => "text",
              "text" => "recomputed on the server",
              "marks" => [%{"type" => "bold"}]
            },
            %{"type" => "text", "text" => ", from the stored tree."}
          ]
        },
        %{
          "type" => "attachment",
          "attrs" => %{
            "key" => "sample-key",
            "filename" => "plan.pdf",
            "content_type" => "application/pdf",
            "byte_size" => 91_233,
            "alt" => nil,
            "caption" => "The URL below changes on every render — it is never stored."
          }
        }
      ]
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="demo">
      <Layouts.flash_group flash={@flash} />
      <header>
        <h1>Coelho</h1>
        <p>Structured rich text for Phoenix. No HTML is stored, anywhere.</p>
      </header>

      <div class="panes">
        <.form for={@form} phx-change="validate" phx-submit="save" class="pane">
          <label>
            Title <input type="text" name={@form[:title].name} value={@form[:title].value} />
          </label>
          <p :for={{message, _} <- @form[:title].errors} class="field-error">{message}</p>

          <.coelho_editor
            field={@form[:body]}
            document_schema={Demo.RichText.schema()}
            placeholder="Write something…"
            upload={@uploads.attachment}
          />

          <p class="hint">
            Drop or paste a file into the editor to attach it, or
            <button type="button" class="link" phx-click="mention">insert a mention</button>
            — a node this application added to the schema.
          </p>

          <button type="submit">Save</button>
        </.form>

        <div class="pane">
          <section :if={@errors != []} class="errors">
            <h2>Validation</h2>
            <ul>
              <li :for={error <- @errors}>{error}</li>
            </ul>
          </section>

          <section>
            <h2>Server rendered HTML</h2>
            <div class="rendered" data-pane="rendered">{Phoenix.HTML.raw(@html)}</div>
          </section>

          <section>
            <h2>What that HTML is</h2>
            <pre data-pane="html">{@html}</pre>
          </section>

          <section>
            <h2>What is stored</h2>
            <pre data-pane="stored">{@json}</pre>
          </section>

          <section>
            <h2>What full text search would index</h2>
            <pre data-pane="text">{@text}</pre>
          </section>
        </div>
      </div>
    </div>
    """
  end
end
