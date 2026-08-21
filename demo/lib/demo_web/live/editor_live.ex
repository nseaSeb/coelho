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
     |> assign(:note, note_document("note"))
     |> assign(:note_open, true)
     |> assign(:note_generation, 1)
     |> assign(:note_locale, :fr)
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

  # The second editor, which has no changeset behind it: a name, a value, a
  # counter, and a flush on the way out. It is here because the last of those
  # cannot be tested anywhere but in a browser, and because nothing else on
  # this page sends its content — what reaches the server is what the flush
  # carried, which is the only way to prove the flush carried it.
  # A language switched while someone is writing. The words change; the undo
  # history and the caret must not — which is the whole reason the editor
  # carries two fingerprints rather than one.
  def handle_event("note_locale", _params, socket) do
    {:noreply, update(socket, :note_locale, &if(&1 == :fr, do: :en, else: :fr))}
  end

  def handle_event("note_toggle", _params, socket) do
    # Closing is not discarding: the generation stays where it is, so the
    # flush the editor pushes on its way out is accepted.
    {:noreply, update(socket, :note_open, &(not &1))}
  end

  def handle_event("note_discard", _params, socket) do
    # This is what the token is for. Discarding closes the editor, so the
    # editor being torn down pushes what was in it — the very content that
    # was just thrown away. Moving the generation is how this refuses it.
    {:noreply,
     socket
     |> assign(:note, Coelho.empty(Demo.RichText.schema()))
     |> assign(:note_open, false)
     |> update(:note_generation, &(&1 + 1))}
  end

  def handle_event("note_flush", %{"token" => token, "document" => document}, socket) do
    # The token an editor carries out is the one it mounted with, and it comes
    # back as a string because it travelled as a DOM attribute.
    if token == to_string(socket.assigns.note_generation) do
      {:noreply, assign(socket, :note, Coelho.sanitize(document, Demo.RichText.schema()))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("mention", _params, socket) do
    # A node the application decides on, built server side against the same
    # schema that will validate it on the way back.
    {:noreply,
     insert_node(
       socket,
       %{"type" => "mention", "attrs" => %{"user_id" => 7, "label" => "@ada"}},
       id: editor_id(socket.assigns.form[:body])
     )}
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
             id: editor_id(socket.assigns.form[:body]),
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

  defp note_labels(:fr), do: %{"bold" => "Gras", "italic" => "Italique"}
  defp note_labels(:en), do: %{"bold" => "Bold", "italic" => "Italic"}

  # `link_placeholder` is deliberately absent from both: what an application
  # does not say keeps its English, and a partial translation should be a
  # partial translation rather than a blank label.
  defp note_field_labels(:fr) do
    %{
      "link_label" => "Adresse du lien",
      "link_hint" => "Videz le champ pour retirer le lien."
    }
  end

  defp note_field_labels(:en) do
    %{"link_label" => "Link address", "link_hint" => "Empty the field to remove the link."}
  end

  defp note_document(text) do
    %{
      "type" => "doc",
      "content" => [
        %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => text}]}
      ]
    }
  end

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
        <.form for={@form} id="post-form" phx-change="validate" phx-submit="save" class="pane">
          <label>
            Title <input type="text" name={@form[:title].name} value={@form[:title].value} />
          </label>
          <p :for={{message, _} <- @form[:title].errors} class="field-error">{message}</p>

          <.coelho_editor
            field={@form[:body]}
            document_schema={Demo.RichText.schema()}
            placeholder="Write something…"
            field_labels={note_field_labels(@note_locale)}
            toolbar={
              ~w(bold italic strike code link heading bullet_list ordered_list blockquote caption align_left align_center)
            }
            upload={@uploads.attachment}
          />

          <p class="hint">
            Drop or paste a file into the editor to attach it, or
            <button type="button" class="link" phx-click="mention">insert a mention</button>
            — a node this application added to the schema.
          </p>

          <button type="submit">Save</button>
        </.form>

        <section class="pane" id="note">
          <h2>Draft note</h2>
          <p class="hint">
            A second editor with no changeset behind it: a name and a value, a
            counter, and a flush that carries the document when the editor
            leaves the page. Type, then hide it — the text arrives. Type, then
            discard it, and the flush from the editor being torn down is
            refused, because it carries a generation this page has moved past.
          </p>

          <button type="button" id="note-toggle" phx-click="note_toggle">
            {if @note_open, do: "Hide", else: "Show"}
          </button>
          <button type="button" id="note-discard" phx-click="note_discard">Discard</button>
          <button type="button" id="note-locale" phx-click="note_locale">
            {if @note_locale == :fr, do: "English", else: "Français"}
          </button>

          <%!-- No phx-change at all: this editor reports on the way out and
                at no other time, which is the shape a debounced form takes
                at the moment the element is removed — the timer goes with
                it and nothing is ever sent. Here it is the only path, so
                what arrives is what the flush carried. --%>
          <div :if={@note_open} id="note-form">
            <.coelho_editor
              name="note[body]"
              value={@note}
              document_schema={Demo.RichText.schema()}
              toolbar={~w(bold italic link)}
              labels={note_labels(@note_locale)}
              field_labels={note_field_labels(@note_locale)}
              maxlength={200}
              flush_event="note_flush"
              flush_token={@note_generation}
              placeholder="Reported when this closes…"
            />
          </div>

          <p id="note-text" class="hint">{Coelho.to_text(@note, Demo.RichText.schema())}</p>
        </section>

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
