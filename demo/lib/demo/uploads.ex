defmodule Demo.Uploads do
  @moduledoc """
  The half of attachments that Coelho deliberately leaves to the application:
  where the bytes go, what a key is allowed to become, and who may read it.

  The demo has no database, so attachment metadata lives in an ETS table
  rather than in `Coelho.Attachment` rows. Everything else is what a real
  application would write.
  """

  use GenServer

  alias Coelho.{Attachment, Attachments, Storage}

  @table __MODULE__
  @root "priv/uploads"

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    File.mkdir_p!(@root)
    {:ok, %{}}
  end

  @doc "The storage the plug and this module share."
  def storage, do: Coelho.Storage.Disk.new(@root)

  @doc """
  The signing secret.

  Derived rather than reused: the endpoint's secret signs sessions, and one
  key should do one job.
  """
  def secret do
    :crypto.hash(:sha256, endpoint_secret() <> "coelho attachments")
  end

  defp endpoint_secret do
    :demo |> Application.fetch_env!(DemoWeb.Endpoint) |> Keyword.fetch!(:secret_key_base)
  end

  @doc "Stores an uploaded file and records what it was."
  def store(path, filename, content_type) do
    key = Attachment.generate_key()

    with :ok <- Storage.put(storage(), key, {:file, path}) do
      size = path |> File.stat!() |> Map.fetch!(:size)

      :ets.insert(
        @table,
        {key, %{filename: filename, content_type: content_type, byte_size: size}}
      )

      {:ok,
       %Attachment{key: key, filename: filename, content_type: content_type, byte_size: size}}
    end
  end

  @doc "What the plug needs to answer with, looked up by key."
  def metadata(key) do
    case :ets.lookup(@table, key) do
      [{^key, metadata}] -> metadata
      [] -> nil
    end
  end

  @doc """
  A one-pixel PNG, for the browser test to paste from another origin.
  """
  def pixel do
    Base.decode64!(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )
  end

  @doc """
  A URL for a key, valid for five minutes.

  This is the resolver the renderer is given. It is called on every render,
  which is why the expiry in the URL keeps moving.
  """
  def url(key), do: Attachments.signed_url("/attachments", key, secret(), expires_in: 300)
end
