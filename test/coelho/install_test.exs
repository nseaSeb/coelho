defmodule Coelho.InstallTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  # What `mix phx.new` leaves behind, near enough: the imports at the top and
  # a LiveSocket whose hooks are a spread.
  @app_js """
  import "phoenix_html"
  import {Socket} from "phoenix"
  import {LiveSocket} from "phoenix_live_view"
  import {hooks as colocatedHooks} from "phoenix-colocated/my_app"

  const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

  const liveSocket = new LiveSocket("/live", Socket, {
    longPollFallback: true,
    params: {_csrf_token: csrfToken},
    hooks: {...colocatedHooks}
  })

  liveSocket.connect()
  """

  @app_css """
  @import "tailwindcss" source(none);
  @source "../css";

  @custom-variant phx-click-loading (.phx-click-loading&, .phx-click-loading &);

  .my-app { color: rebeccapurple; }
  """

  defp app(tmp_dir) do
    File.mkdir_p!(Path.join(tmp_dir, "assets/js"))
    File.mkdir_p!(Path.join(tmp_dir, "assets/css"))
    File.write!(Path.join(tmp_dir, "assets/js/app.js"), @app_js)
    File.write!(Path.join(tmp_dir, "assets/css/app.css"), @app_css)
    File.write!(Path.join(tmp_dir, "assets/package.json"), ~s({"name":"my_app"}))
    tmp_dir
  end

  defp install(tmp_dir, args \\ []) do
    File.cd!(tmp_dir, fn ->
      capture_io(fn -> Mix.Tasks.Coelho.Install.run(["--no-npm", "--no-migration"] ++ args) end)
    end)
  end

  @style_import ~s(@import "../../deps/coelho/assets/css/coelho.css";)

  defp read(tmp_dir, path), do: File.read!(Path.join(tmp_dir, path))

  describe "the hook" do
    test "is imported and added to the LiveSocket", %{tmp_dir: tmp_dir} do
      app(tmp_dir)
      install(tmp_dir)

      js = read(tmp_dir, "assets/js/app.js")

      assert js =~ ~s(import { Coelho } from "../../deps/coelho/assets/js/coelho.js")
      assert js =~ "hooks: {Coelho, ...colocatedHooks}"
    end

    test "goes after the imports already there, not before them" do
      # An import before `import {Socket} from "phoenix"` is legal and reads
      # as though Coelho came first, which it did not.
      tmp_dir = app(Path.join(System.tmp_dir!(), "coelho-#{System.unique_integer([:positive])}"))
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      install(tmp_dir)

      lines = tmp_dir |> read("assets/js/app.js") |> String.split("\n")
      coelho = Enum.find_index(lines, &(&1 =~ "coelho.js"))

      last_other =
        lines
        |> Enum.with_index()
        |> Enum.filter(fn {l, _} -> l =~ ~r/^import / and not (l =~ "coelho") end)
        |> List.last()
        |> elem(1)

      assert coelho == last_other + 1
    end

    test "is left alone on a second run", %{tmp_dir: tmp_dir} do
      app(tmp_dir)
      install(tmp_dir)
      once = read(tmp_dir, "assets/js/app.js")

      output = install(tmp_dir)

      assert read(tmp_dir, "assets/js/app.js") == once
      assert output =~ "already imported"
    end

    test "goes after an import that spans several lines, not into the middle of it", %{
      tmp_dir: tmp_dir
    } do
      # `import {\n  LiveSocket\n} from "…"` has `import {` as its last line
      # matching `import`, and inserting there is a syntax error in the file
      # the whole bundle is built from — on the first run of the command this
      # task exists to be.
      app(tmp_dir)

      File.write!(Path.join(tmp_dir, "assets/js/app.js"), """
      import "phoenix_html"
      import {
        LiveSocket
      } from "phoenix_live_view"

      const liveSocket = new LiveSocket("/live", Socket, {hooks: {}})
      """)

      install(tmp_dir)
      lines = tmp_dir |> read("assets/js/app.js") |> String.split("\n")

      assert Enum.at(lines, 3) == ~s(} from "phoenix_live_view")
      assert Enum.at(lines, 4) =~ "coelho.js"
    end

    test "cuts on bytes, so prose above the LiveSocket does not move the seam", %{
      tmp_dir: tmp_dir
    } do
      # The file Phoenix generates is full of comments, and a single em dash
      # in one of them is enough: regex offsets are bytes and String.split_at
      # counts characters, which produced `{..Coelho, .colocatedHooks}`.
      app(tmp_dir)

      File.write!(
        Path.join(tmp_dir, "assets/js/app.js"),
        "// une remarque — avec un tiret cadratin, et un autre —\n" <> @app_js
      )

      install(tmp_dir)

      assert read(tmp_dir, "assets/js/app.js") =~ "hooks: {Coelho, ...colocatedHooks}"
    end

    test "is not fooled by a commented-out example", %{tmp_dir: tmp_dir} do
      # The file Phoenix generates carries commented imports, and an
      # application that pasted one from a README would otherwise be told it
      # was already wired.
      app(tmp_dir)

      File.write!(
        Path.join(tmp_dir, "assets/js/app.js"),
        ~s(// import { Coelho } from "../../deps/coelho/assets/js/coelho.js"\n) <> @app_js
      )

      install(tmp_dir)
      js = read(tmp_dir, "assets/js/app.js")

      assert js =~ "hooks: {Coelho, ...colocatedHooks}"
      assert length(String.split(js, "coelho.js")) == 3
    end

    test "says what to do rather than guessing at an unfamiliar LiveSocket", %{tmp_dir: tmp_dir} do
      app(tmp_dir)
      File.write!(Path.join(tmp_dir, "assets/js/app.js"), "import {Socket} from \"phoenix\"\n")

      output = install(tmp_dir)

      assert output =~ "and `Coelho` to the LiveSocket's hooks"
      refute read(tmp_dir, "assets/js/app.js") =~ "hooks"
    end
  end

  describe "the stylesheet" do
    test "is imported after the last at-rule, because CSS refuses a late @import", %{
      tmp_dir: tmp_dir
    } do
      app(tmp_dir)
      install(tmp_dir)

      lines = tmp_dir |> read("assets/css/app.css") |> String.split("\n")
      coelho = Enum.find_index(lines, &(&1 =~ "coelho.css"))
      rule = Enum.find_index(lines, &(&1 =~ ".my-app"))

      assert coelho < rule
      assert Enum.at(lines, coelho - 1) =~ "@custom-variant"
    end

    test "is left alone on a second run", %{tmp_dir: tmp_dir} do
      app(tmp_dir)
      install(tmp_dir)
      once = read(tmp_dir, "assets/css/app.css")

      assert install(tmp_dir) =~ "already imported"
      assert read(tmp_dir, "assets/css/app.css") == once
    end

    test "goes after an at-rule's block, not inside it", %{tmp_dir: tmp_dir} do
      # `@plugin "…" { … }` spans lines, and a Phoenix stylesheet is full of
      # them. The last line *matching* an at-rule is the block's opening one,
      # and an @import written there is invalid CSS and a failed build.
      app(tmp_dir)

      File.write!(Path.join(tmp_dir, "assets/css/app.css"), """
      @import "tailwindcss" source(none);

      @plugin "../vendor/daisyui-theme" {
        name: "dark";
      }
      """)

      install(tmp_dir)
      lines = tmp_dir |> read("assets/css/app.css") |> String.split("\n")
      coelho = Enum.find_index(lines, &(&1 =~ "coelho.css"))

      assert Enum.at(lines, coelho - 1) == "}"
      assert Enum.at(lines, coelho) == @style_import
    end

    test "goes to the top of a stylesheet with no at-rules at all", %{tmp_dir: tmp_dir} do
      app(tmp_dir)
      File.write!(Path.join(tmp_dir, "assets/css/app.css"), ".my-app { color: red; }\n")

      install(tmp_dir)

      assert tmp_dir |> read("assets/css/app.css") |> String.starts_with?("@import")
    end
  end

  describe "the browser packages" do
    test "are the ones the hook imports, not a list kept by hand" do
      # Read from Coelho's own peerDependencies when the task compiles, so the
      # two cannot drift.
      names = Enum.map(Mix.Tasks.Coelho.Install.packages(), &elem(&1, 0))

      assert "prosemirror-view" in names
      assert "@nseaprotector/acme-script" in names
      assert length(names) == 9
    end

    test "a name declared at another version is named, not called present", %{tmp_dir: tmp_dir} do
      # Checking the name alone told an application pinned to an older
      # prosemirror-view that everything was there, and it failed inside
      # coelho.js a long way from the cause.
      app(tmp_dir)

      declared =
        Mix.Tasks.Coelho.Install.packages()
        |> Map.new()
        |> Map.put("prosemirror-view", "^1.20.0")

      File.write!(
        Path.join(tmp_dir, "assets/package.json"),
        JSON.encode!(%{"name" => "my_app", "dependencies" => declared})
      )

      output = install(tmp_dir)

      assert output =~ "prosemirror-view@^1.20.0"
      refute output =~ "already there"
    end

    test "and the same versions are left alone", %{tmp_dir: tmp_dir} do
      app(tmp_dir)

      File.write!(
        Path.join(tmp_dir, "assets/package.json"),
        JSON.encode!(%{
          "name" => "my_app",
          "dependencies" => Map.new(Mix.Tasks.Coelho.Install.packages())
        })
      )

      assert install(tmp_dir) =~ "already there"
    end

    test "are printed rather than installed when npm is declined", %{tmp_dir: tmp_dir} do
      app(tmp_dir)

      output = install(tmp_dir)

      assert output =~ "npm install --prefix assets"
      assert output =~ "prosemirror-state@"
    end
  end

  describe "--dry-run" do
    test "changes nothing", %{tmp_dir: tmp_dir} do
      app(tmp_dir)
      before = {read(tmp_dir, "assets/js/app.js"), read(tmp_dir, "assets/css/app.css")}

      output = install(tmp_dir, ["--dry-run"])

      assert {read(tmp_dir, "assets/js/app.js"), read(tmp_dir, "assets/css/app.css")} == before
      assert output =~ "app.js"
      assert output =~ "app.css"
    end
  end

  describe "an application that is not one" do
    test "says which file is missing rather than raising", %{tmp_dir: tmp_dir} do
      output = install(tmp_dir)

      assert output =~ "not found — is this an application root?"
    end
  end
end
