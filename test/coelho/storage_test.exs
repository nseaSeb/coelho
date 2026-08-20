defmodule Coelho.StorageTest do
  use ExUnit.Case, async: true

  alias Coelho.Storage
  alias Coelho.Storage.Disk

  setup %{tmp_dir: tmp_dir} do
    %{storage: Disk.new(tmp_dir), key: Coelho.Attachment.generate_key()}
  end

  @moduletag :tmp_dir

  describe "round trip" do
    test "stores and reads bytes", %{storage: storage, key: key} do
      assert :ok = Storage.put(storage, key, {:binary, "hello"})
      assert {:ok, "hello"} = Storage.read(storage, key)
      assert Storage.exists?(storage, key)
    end

    test "stores from a file", %{storage: storage, key: key, tmp_dir: tmp_dir} do
      source = Path.join(tmp_dir, "source.txt")
      File.write!(source, "from a file")

      assert :ok = Storage.put(storage, key, {:file, source})
      assert {:ok, "from a file"} = Storage.read(storage, key)
    end

    test "replaces what was there", %{storage: storage, key: key} do
      :ok = Storage.put(storage, key, {:binary, "first"})
      :ok = Storage.put(storage, key, {:binary, "second"})

      assert {:ok, "second"} = Storage.read(storage, key)
    end

    test "deletes, and deleting nothing is not an error", %{storage: storage, key: key} do
      :ok = Storage.put(storage, key, {:binary, "x"})

      assert :ok = Storage.delete(storage, key)
      refute Storage.exists?(storage, key)
      assert :ok = Storage.delete(storage, key)
    end

    test "offers a local path so a plug can send the file", %{storage: storage, key: key} do
      :ok = Storage.put(storage, key, {:binary, "x"})

      assert {:ok, path} = Storage.path(storage, key)
      assert File.regular?(path)
    end

    test "shards on the first two characters of the key", %{storage: storage, key: key} do
      {:ok, path} = Storage.path(storage, key)

      assert path |> Path.dirname() |> Path.basename() == String.slice(key, 0, 2)
    end
  end

  describe "keys arriving from a URL" do
    test "a key that is not the shape we hand out never becomes a path", %{storage: storage} do
      for key <- ["../../etc/passwd", "a/b", "..", "", "x", "a.b", "key with space"] do
        assert :error = Storage.path(storage, key)
        assert {:error, :invalid_key} = Storage.read(storage, key)
        assert {:error, :invalid_key} = Storage.put(storage, key, {:binary, "x"})
        refute Storage.exists?(storage, key)
      end
    end

    test "traversal cannot escape the root", %{storage: storage, tmp_dir: tmp_dir} do
      assert {:error, :invalid_key} =
               Storage.put(storage, "../escaped", {:binary, "should not be written"})

      refute File.exists?(Path.join(Path.dirname(tmp_dir), "escaped"))
    end
  end

  describe "signed URLs" do
    @secret :crypto.strong_rand_bytes(32)

    test "verify a URL this key produced", %{key: key} do
      url = Coelho.Attachments.signed_url("/attachments", key, @secret)

      assert %URI{path: path, query: query} = URI.parse(url)
      assert path == "/attachments/#{key}"
      assert :ok = Coelho.Attachments.verify(key, URI.decode_query(query), @secret)
    end

    test "a signature does not carry to another key", %{key: key} do
      other = Coelho.Attachment.generate_key()
      params = "/a" |> Coelho.Attachments.signed_url(key, @secret) |> query()

      assert {:error, :invalid} = Coelho.Attachments.verify(other, params, @secret)
    end

    test "a signature does not survive another secret", %{key: key} do
      params = "/a" |> Coelho.Attachments.signed_url(key, @secret) |> query()

      assert {:error, :invalid} =
               Coelho.Attachments.verify(key, params, :crypto.strong_rand_bytes(32))
    end

    test "the expiry is part of what is signed", %{key: key} do
      params = "/a" |> Coelho.Attachments.signed_url(key, @secret) |> query()

      stretched =
        Map.put(params, "expires", to_string(String.to_integer(params["expires"]) + 3600))

      assert {:error, :invalid} = Coelho.Attachments.verify(key, stretched, @secret)
    end

    test "a valid signature stops working when it expires", %{key: key} do
      params =
        "/a" |> Coelho.Attachments.signed_url(key, @secret, expires_in: 60, now: 1000) |> query()

      assert :ok = Coelho.Attachments.verify(key, params, @secret, now: 1059)
      assert :ok = Coelho.Attachments.verify(key, params, @secret, now: 1060)
      assert {:error, :expired} = Coelho.Attachments.verify(key, params, @secret, now: 1061)
    end

    test "missing or malformed parameters are refused", %{key: key} do
      for params <- [%{}, %{"expires" => "soon", "signature" => "x"}, %{"signature" => "x"}] do
        assert {:error, :invalid} = Coelho.Attachments.verify(key, params, @secret)
      end
    end
  end

  defp query(url), do: url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
end
