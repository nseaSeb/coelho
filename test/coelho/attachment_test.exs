defmodule Coelho.AttachmentTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Coelho.Attachment

  describe "changeset/2" do
    test "requires a key and a filename" do
      changeset = Attachment.changeset(%Attachment{}, %{})

      refute changeset.valid?
      assert {"can't be blank", _} = changeset.errors[:key]
      assert {"can't be blank", _} = changeset.errors[:filename]
    end

    test "accepts metadata the application cares about" do
      changeset =
        Attachment.changeset(%Attachment{}, %{
          key: Attachment.generate_key(),
          filename: "plan.pdf",
          content_type: "application/pdf",
          byte_size: 91_233,
          metadata: %{"pages" => 4}
        })

      assert changeset.valid?
    end

    test "refuses a negative size" do
      changeset = Attachment.changeset(%Attachment{}, %{key: "k", filename: "a", byte_size: -1})

      refute changeset.valid?
    end
  end

  describe "generate_key/0" do
    test "is URL safe and does not repeat" do
      keys = Enum.map(1..100, fn _ -> Attachment.generate_key() end)

      assert length(Enum.uniq(keys)) == 100
      assert Enum.all?(keys, &(&1 =~ ~r/\A[A-Za-z0-9_-]+\z/))
    end
  end

  describe "to_node/1" do
    test "produces a node the default schema accepts" do
      attachment = %Attachment{
        key: Attachment.generate_key(),
        filename: "plan.pdf",
        content_type: "application/pdf",
        byte_size: 91_233
      }

      document = %{"type" => "doc", "content" => [Attachment.to_node(attachment)]}

      assert {:ok, _} = Coelho.validate(document)
    end
  end

  describe "mix coelho.gen.migration" do
    @tag :tmp_dir
    test "writes a migration creating the attachments table", %{tmp_dir: tmp_dir} do
      file =
        capture_io(fn ->
          send(self(), Mix.Tasks.Coelho.Gen.Migration.run(["--path", tmp_dir]))
        end)

      assert_received path
      assert File.exists?(path)
      assert Path.basename(path) =~ ~r/\A\d{14}_create_coelho_attachments\.exs\z/
      assert file =~ "creating"

      contents = File.read!(path)
      assert contents =~ "create table(:coelho_attachments"
      assert contents =~ "create unique_index(:coelho_attachments, [:key])"
      assert Code.string_to_quoted(contents) |> elem(0) == :ok
    end
  end

  describe "generate_key/1 with a prefix" do
    test "shares a shard directory with every other tenant, which is why Disk is not for it" do
      # The sharding is on the first two characters, and a prefix makes those
      # the same for everyone. Documented rather than worked around: the
      # prefix is for object storage, where listing by prefix is the point.
      {:ok, one} =
        Coelho.Storage.path(
          Coelho.Storage.Disk.new("/tmp"),
          Attachment.generate_key(prefix: "org_acme")
        )

      {:ok, other} =
        Coelho.Storage.path(
          Coelho.Storage.Disk.new("/tmp"),
          Attachment.generate_key(prefix: "org_beta")
        )

      assert Path.dirname(one) == Path.dirname(other)
    end

    test "keeps the key one URL-safe segment, which is what the storage needs" do
      key = Attachment.generate_key(prefix: "org_acme")

      assert String.starts_with?(key, "org_acme-")
      assert String.match?(key, ~r/\A[A-Za-z0-9_-]+\z/)
      assert {:ok, _path} = Coelho.Storage.path(Coelho.Storage.Disk.new("/tmp"), key)
    end

    test "is still unguessable — the prefix names the tenant, not the file" do
      keys = for _ <- 1..50, do: Attachment.generate_key(prefix: "org_acme")

      assert length(Enum.uniq(keys)) == 50
    end

    test "refuses a prefix that would break the key into two segments" do
      for bad <- ["org/acme", "org acme", "org.acme", ".."] do
        assert_raise ArgumentError, ~r/URL safe/, fn -> Attachment.generate_key(prefix: bad) end
      end
    end

    test "refuses a prefix that is not a string" do
      assert_raise ArgumentError, ~r/must be a string/, fn ->
        Attachment.generate_key(prefix: :org_acme)
      end
    end

    test "without one, nothing changes" do
      key = Attachment.generate_key()

      refute key =~ "-org"
      assert String.match?(key, ~r/\A[A-Za-z0-9_-]+\z/)
    end
  end
end
