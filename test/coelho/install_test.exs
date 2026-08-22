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
    test "is imported right after the last @import, because CSS refuses a late one", %{
      tmp_dir: tmp_dir
    } do
      # After the imports and nothing else: CSS allows an `@import` only
      # after `@charset`, `@layer` statements and other imports. Tailwind's
      # at-rules are not part of that preamble, so anchoring on them wrote
      # the import after a `@custom-variant` two hundred lines into a real
      # Phoenix 1.8 stylesheet — past rules, where CSS drops it.
      app(tmp_dir)
      install(tmp_dir)

      lines = tmp_dir |> read("assets/css/app.css") |> String.split("\n")
      coelho = Enum.find_index(lines, &(&1 =~ "coelho.css"))

      assert Enum.at(lines, coelho - 1) =~ ~s(@import "tailwindcss")
      assert Enum.at(lines, coelho + 1) =~ "@source"
    end

    test "is left alone on a second run", %{tmp_dir: tmp_dir} do
      app(tmp_dir)
      install(tmp_dir)
      once = read(tmp_dir, "assets/css/app.css")

      assert install(tmp_dir) =~ "already imported"
      assert read(tmp_dir, "assets/css/app.css") == once
    end

    test "stays out of a `@plugin` block and before it", %{tmp_dir: tmp_dir} do
      # `@plugin "…" { … }` spans lines. An @import written into the block
      # is invalid CSS; one written after it is dropped just the same,
      # because the block ends the import-allowing preamble.
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
      plugin = Enum.find_index(lines, &(&1 =~ "@plugin"))

      assert Enum.at(lines, coelho) == @style_import
      assert Enum.at(lines, coelho - 1) =~ ~s(@import "tailwindcss")
      assert coelho < plugin
    end

    test "goes to the top of a stylesheet with no at-rules at all", %{tmp_dir: tmp_dir} do
      app(tmp_dir)
      File.write!(Path.join(tmp_dir, "assets/css/app.css"), ".my-app { color: red; }\n")

      install(tmp_dir)

      assert tmp_dir |> read("assets/css/app.css") |> String.starts_with?("@import")
    end
  end

  describe "esbuild" do
    # esbuild resolves coelho.js's bare imports from deps/coelho/, which
    # never reaches assets/node_modules on its own. The task diagnoses the
    # config rather than editing it — the profile name is the application's
    # own — and says nothing when there is nothing to say.
    setup do
      on_exit(fn ->
        for {key, _} <- Application.get_all_env(:esbuild),
            do: Application.delete_env(:esbuild, key)
      end)
    end

    test "says nothing when the application does not use esbuild", %{tmp_dir: tmp_dir} do
      app(tmp_dir)

      refute install(tmp_dir) =~ "config/config.exs"
    end

    test "keeps a profile whose NODE_PATH list covers assets/node_modules", %{tmp_dir: tmp_dir} do
      app(tmp_dir)

      Application.put_env(:esbuild, :version, "0.25.4")

      Application.put_env(:esbuild, :my_app,
        args: ~w(js/app.js --bundle),
        cd: Path.join(tmp_dir, "assets"),
        env: %{
          "NODE_PATH" => [Path.join(tmp_dir, "assets/node_modules"), Path.join(tmp_dir, "deps")]
        }
      )

      assert install(tmp_dir) =~ "esbuild can find the browser packages"
    end

    test "accepts the string form too, joined with the OS separator", %{tmp_dir: tmp_dir} do
      app(tmp_dir)

      Application.put_env(:esbuild, :my_app,
        args: ~w(js/app.js --bundle),
        env: %{
          "NODE_PATH" =>
            Path.join(tmp_dir, "deps") <> ":" <> Path.join(tmp_dir, "assets/node_modules")
        }
      )

      assert install(tmp_dir) =~ "esbuild can find the browser packages"
    end

    test "says what to add when no profile reaches the packages", %{tmp_dir: tmp_dir} do
      app(tmp_dir)

      Application.put_env(:esbuild, :my_app,
        args: ~w(js/app.js --bundle),
        env: %{"NODE_PATH" => [Path.join(tmp_dir, "deps")]}
      )

      out = install(tmp_dir)

      assert out =~ "config/config.exs"
      assert out =~ ~s[Path.expand("../assets/node_modules", __DIR__)]
      assert out =~ ":my_app"
    end

    test "names every profile that is short, rather than clearing the lot", %{tmp_dir: tmp_dir} do
      # Which profile bundles app.js is not something to guess at, and
      # "some other profile covers it" is the all-clear that hides the very
      # failure this step exists to diagnose.
      app(tmp_dir)

      Application.put_env(:esbuild, :my_app,
        args: ~w(js/app.js --bundle),
        env: %{"NODE_PATH" => [Path.join(tmp_dir, "deps")]}
      )

      Application.put_env(:esbuild, :ssr,
        args: ~w(js/ssr.js --bundle),
        env: %{"NODE_PATH" => [Path.join(tmp_dir, "assets/node_modules")]}
      )

      out = install(tmp_dir)

      assert out =~ ":my_app"
      refute out =~ "esbuild can find the browser packages"
    end

    test "reads an `env` given as a keyword list, which esbuild accepts too", %{tmp_dir: tmp_dir} do
      # The esbuild package runs `Map.new/1` over `env`, so a keyword list
      # is valid config; reading only the map form printed the consigne at
      # an application whose config was already right, on every run.
      app(tmp_dir)

      Application.put_env(:esbuild, :my_app,
        args: ~w(js/app.js --bundle),
        env: [{"NODE_PATH", Path.join(tmp_dir, "assets/node_modules")}]
      )

      assert install(tmp_dir) =~ "esbuild can find the browser packages"
    end

    test "resolves a relative NODE_PATH from the profile's cd, as esbuild does", %{
      tmp_dir: tmp_dir
    } do
      app(tmp_dir)

      Application.put_env(:esbuild, :my_app,
        args: ~w(js/app.js --bundle),
        cd: Path.join(tmp_dir, "assets"),
        env: %{"NODE_PATH" => "node_modules"}
      )

      assert install(tmp_dir) =~ "esbuild can find the browser packages"
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

    test "are installed with the manager the application already uses", %{tmp_dir: tmp_dir} do
      # Installing with npm into an application that uses pnpm leaves two
      # layouts of node_modules in one project, and the one that breaks is
      # whichever esbuild does not resolve through — which surfaces inside
      # the hook at mount, a long way from the cause.
      app(tmp_dir)
      File.write!(Path.join(tmp_dir, "assets/pnpm-lock.yaml"), "lockfileVersion: '9.0'\n")

      assert install(tmp_dir) =~ "pnpm --dir assets add"
    end

    test "are installed with the manager named at the project root", %{tmp_dir: tmp_dir} do
      app(tmp_dir)
      File.write!(Path.join(tmp_dir, "yarn.lock"), "")

      assert install(tmp_dir) =~ "yarn --cwd assets add"
    end

    test "fall back to npm, which is what a generated application has", %{tmp_dir: tmp_dir} do
      app(tmp_dir)

      assert File.cd!(tmp_dir, fn -> Mix.Tasks.Coelho.Install.installer() end) ==
               {"npm", "npm install --prefix assets"}
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
