defmodule Mix.Tasks.Coelho.Install do
  @shortdoc "Wires Coelho into an application: hook, styles, npm packages, migration"

  @moduledoc """
  Does the four things that stand between adding the dependency and typing in
  an editor.

      mix coelho.install

  Which are: the browser packages Coelho's hook imports, the hook itself in
  `assets/js/app.js`, the stylesheet in `assets/css/app.css`, and the
  attachments migration. Every one of them is small and none of them is
  guessable, which is a poor trade for the first ten minutes of trying a
  library.

  It changes nothing it does not have to. Run it twice and the second run
  reports that everything is already there.

  ## What it touches

    * `assets/package.json` — the packages `coelho.js` imports, taken from
      Coelho's own `peerDependencies` so the list cannot drift from what the
      hook actually needs. Installed with `npm`, after asking
    * `assets/js/app.js` — the import, and `Coelho` added to the LiveSocket's
      `hooks`. Only when the file's shape is recognised; otherwise the two
      lines are printed for you to place
    * `assets/css/app.css` — the stylesheet, imported after the last `@import`
      already there, because CSS refuses one that follows a rule
    * `config/config.exs` — checked, never edited: esbuild resolves
      `coelho.js`'s bare imports from `deps/coelho/`, which never reaches
      `assets/node_modules` on its own. When no profile's `NODE_PATH` covers
      it, the task prints the path to add
    * `priv/repo/migrations` — `mix coelho.gen.migration`, which is the only
      part an application without attachments does not need

  ## Options

    * `--dry-run` — say what would change and change nothing
    * `--yes` — do not ask before running `npm install`
    * `--no-npm` — print the command instead of running it
    * `--no-migration` — skip the attachments table

  """

  use Mix.Task

  # Read where the source tree is, which is when this compiles, and kept as an
  # external resource so that editing the manifest recompiles the task. The
  # alternative — listing the packages here — is a list that drifts from the
  # one the hook actually imports.
  @manifest Path.expand(Path.join([__DIR__, "..", "..", "..", "assets", "package.json"]))
  @external_resource @manifest
  @packages @manifest |> File.read!() |> JSON.decode!() |> Map.fetch!("peerDependencies")

  @hook_import ~s(import { Coelho } from "../../deps/coelho/assets/js/coelho.js")
  @style_import ~s(@import "../../deps/coelho/assets/css/coelho.css";)

  @impl true
  def run(args) do
    {opts, _argv} =
      OptionParser.parse!(args,
        strict: [dry_run: :boolean, yes: :boolean, npm: :boolean, migration: :boolean]
      )

    opts = Keyword.merge([dry_run: false, yes: false, npm: true, migration: true], opts)

    packages(opts)
    hook(opts)
    styles(opts)
    esbuild()
    migration(opts)

    Mix.shell().info("")
    Mix.shell().info("Coelho is wired in. `<.coelho_editor field={@form[:body]} />` renders.")
  end

  @doc """
  The browser packages the hook imports, as `{name, requirement}` pairs.
  """
  @spec packages() :: [{String.t(), String.t()}]
  def packages, do: Enum.sort(@packages)

  # -- npm ------------------------------------------------------------------

  defp packages(opts) do
    args = Enum.map(packages(), fn {name, requirement} -> name <> "@" <> requirement end)
    command = "npm install --prefix assets " <> Enum.join(args, " ")

    cond do
      installed?() -> say(:kept, "assets/package.json", "the browser packages are already there")
      mismatched() != [] -> say(:todo, "assets/package.json", disagreement(command))
      run_npm?(opts, args) -> install_packages(command, length(args))
      true -> say(:todo, "assets/package.json", "run: " <> command)
    end
  end

  defp disagreement(command) do
    "declares " <>
      Enum.join(mismatched(), ", ") <> " — the hook needs what is below; run: " <> command
  end

  defp run_npm?(opts, args) do
    opts[:npm] and not opts[:dry_run] and
      (opts[:yes] or Mix.shell().yes?("Install #{length(args)} browser packages with npm?"))
  end

  # npm exits non-zero for a network that is not there, a registry that says
  # no, a version that will not resolve. Discarding that told the reader the
  # editor would render with none of its packages present.
  defp install_packages(command, count) do
    case Mix.shell().cmd(command) do
      0 -> say(:done, "assets/package.json", "installed #{count} packages")
      status -> say(:todo, "assets/package.json", "npm exited #{status}; run: " <> command)
    end
  end

  # The requirement and not only the name. An application pinned to an older
  # `prosemirror-view` would otherwise be told everything was there and fail
  # inside `coelho.js`, a long way from the cause.
  defp installed? do
    declared = declared()

    Enum.all?(packages(), fn {name, requirement} -> declared[name] == requirement end)
  end

  defp declared do
    with {:ok, contents} <- File.read("assets/package.json"),
         {:ok, manifest} <- JSON.decode(contents) do
      Map.merge(
        Map.get(manifest, "dependencies", %{}),
        Map.get(manifest, "devDependencies", %{})
      )
    else
      _other -> %{}
    end
  end

  # Named, because "run npm install" on an application that already declares
  # the package reads as noise until it says which one disagrees.
  defp mismatched do
    declared = declared()

    for {name, requirement} <- packages(),
        declared[name] not in [nil, requirement],
        do: "#{name}@#{declared[name]}"
  end

  # -- The hook -------------------------------------------------------------

  defp hook(opts) do
    path = "assets/js/app.js"

    with {:ok, source} <- read(path),
         false <- Regex.match?(~r/^[^\/\n]*\bimport\b[^\n]*coelho\.js/m, source) do
      case wire_hook(source) do
        {:ok, wired} ->
          write(path, wired, opts, "imported the hook and added it to the LiveSocket")

        :error ->
          # Every application's app.js is its own, and a LiveSocket built in a
          # shape this does not recognise is not a reason to rewrite it badly.
          say(
            :todo,
            path,
            "add:\n      #{@hook_import}\n      …and `Coelho` to the LiveSocket's hooks"
          )
      end
    else
      true -> say(:kept, path, "the hook is already imported")
      {:error, reason} -> say(:todo, path, reason)
    end
  end

  # A line that *mentions* coelho.js is not a line that imports it: the file
  # Phoenix generates carries commented examples, and an application that
  # pasted one would otherwise be told it was already wired.
  #
  # The import goes after the last one already there, and `Coelho` right
  # inside the hooks object — which is a textual edit and stays one, because
  # parsing JavaScript to add a key is a dependency and a new way to be wrong.
  defp wire_hook(source) do
    with {:ok, imported} <- after_last_import(source) do
      into_hooks(imported)
    end
  end

  # After the last import *statement*, which is not the last line matching
  # `import`. An import spanning several lines —
  #
  #     import {
  #       LiveSocket
  #     } from "phoenix_live_view"
  #
  # — has `import {` as its last matching line, and inserting after that puts
  # the new import in the middle of the old one: a syntax error, in the file
  # the whole bundle is built from, on the first run of the command this task
  # exists to be.
  defp after_last_import(source) do
    source
    |> String.split("\n")
    |> Enum.with_index()
    |> Enum.reduce({nil, false}, fn {line, index}, {last, open?} ->
      open? = open? or Regex.match?(~r/^\s*import\b/, line)

      if open? and Regex.match?(~r/\bfrom\s*["']|^\s*import\s*["']/, line) do
        {index, false}
      else
        {last, open?}
      end
    end)
    |> case do
      {nil, _open?} -> :error
      {index, _open?} -> {:ok, insert_at(source, index + 1, @hook_import)}
    end
  end

  defp into_hooks(source) do
    case Regex.run(~r/hooks:\s*\{/, source, return: :index) do
      [{start, length}] ->
        # Byte offsets, and cut as bytes. `String.split_at/2` counts
        # *characters*, so a single em dash anywhere above the LiveSocket —
        # and the file Phoenix generates is full of prose — moves the cut and
        # produces `{..Coelho, .colocatedHooks}`.
        at = start + length
        head = binary_part(source, 0, at)
        tail = binary_part(source, at, byte_size(source) - at)

        {:ok, head <> "Coelho, " <> tail}

      nil ->
        :error
    end
  end

  # -- The stylesheet -------------------------------------------------------

  defp styles(opts) do
    path = "assets/css/app.css"

    with {:ok, source} <- read(path),
         false <- Regex.match?(~r/^\s*@import[^\n]*coelho\.css/m, source) do
      # After the last at-rule of the preamble: CSS refuses an `@import` that
      # follows an ordinary rule, so appending would be invalid rather than
      # merely untidy. After the rule *ends*, though — `@plugin "…" { … }`
      # spans lines, and a Phoenix stylesheet is full of them.
      write(path, after_last_at_rule(source), opts, "imported the stylesheet")
    else
      true -> say(:kept, path, "the stylesheet is already imported")
      {:error, reason} -> say(:todo, path, reason)
    end
  end

  # Only what may precede an `@import`: CSS allows one after `@charset`,
  # `@layer` statements and other imports, and nothing else — a `@layer`
  # statement always precedes the imports, so anchoring on the imports
  # themselves covers it. Anchoring on Tailwind's at-rules instead put the
  # import after a `@custom-variant` two hundred lines into a Phoenix 1.8
  # stylesheet, which CSS refuses.
  @at_rule ~r/^\s*@(import|charset)\b/

  # Brace depth, because an at-rule ends where its block closes and not where
  # its name appears. A line-based "last match" would write the import into
  # the middle of one that spans lines.
  defp after_last_at_rule(source) do
    source
    |> String.split("\n")
    |> Enum.with_index()
    |> Enum.reduce({nil, 0, false}, fn {line, index}, {last, depth, in_rule?} ->
      in_rule? = in_rule? or (depth == 0 and Regex.match?(@at_rule, line))
      depth = depth + count(line, "{") - count(line, "}")

      if in_rule? and depth <= 0 do
        {index, 0, false}
      else
        {last, max(depth, 0), in_rule?}
      end
    end)
    |> case do
      {nil, _depth, _in_rule?} -> @style_import <> "\n" <> source
      {index, _depth, _in_rule?} -> insert_at(source, index + 1, @style_import)
    end
  end

  defp count(line, character), do: line |> String.graphemes() |> Enum.count(&(&1 == character))

  # -- esbuild --------------------------------------------------------------

  # `coelho.js` imports its ProseMirror packages by bare specifier, and
  # esbuild resolves those from the *importing* file — which lives under
  # `deps/coelho/`, from where walking up never reaches the
  # `assets/node_modules` the npm step just filled. The fix is one path in
  # the profile's NODE_PATH; but the config is the application's own keyword
  # tree, under a profile name of its choosing, so as with an unfamiliar
  # `app.js` the task says what to add rather than editing it. It stays
  # quiet both when no profile needs it and when the application does not
  # use esbuild at all — a consigne printed on every run is one the reader
  # learns to ignore.
  defp esbuild do
    profiles =
      for {name, value} <- Application.get_all_env(:esbuild),
          Keyword.keyword?(value),
          do: {name, value}

    case Enum.reject(profiles, &finds_browser_packages?/1) do
      _none when profiles == [] ->
        :ok

      [] ->
        say(:kept, "config/config.exs", "esbuild can find the browser packages")

      missing ->
        # Named, and every one of them: which profile bundles `app.js` is
        # not something to guess at, and "some other profile covers it" is
        # the all-clear that hides the very failure this step exists for.
        say(
          :todo,
          "config/config.exs",
          "add `Path.expand(\"../assets/node_modules\", __DIR__)` to the NODE_PATH " <>
            "list of #{profile_names(missing)} (a list — esbuild joins it with the " <>
            "OS separator; and keep what is already there, `Mix.Project.build_path()` " <>
            "is what resolves colocated hooks)"
        )
    end
  end

  defp profile_names(profiles) do
    Enum.map_join(profiles, ", ", fn {name, _profile} -> inspect(name) end)
  end

  # A relative entry is esbuild's to resolve, and it resolves it from the
  # profile's `cd:` — so that is what it is expanded against here. An
  # absolute one is unaffected by the base.
  defp finds_browser_packages?({_name, profile}) do
    target = Path.expand("assets/node_modules")
    base = Keyword.get(profile, :cd, File.cwd!())

    profile
    |> Keyword.get(:env, %{})
    |> node_path()
    |> Enum.any?(&(Path.expand(&1, base) == target))
  end

  # A NODE_PATH may be a list of paths or a string joined with the OS
  # separator. The `env` around it may be a map or a keyword list: the
  # esbuild package runs `Map.new/1` over it, so both are valid config and
  # reading only the map would print the consigne at an application whose
  # config is already right.
  defp node_path(env) when is_map(env) or is_list(env) do
    separator = if match?({:win32, _}, :os.type()), do: ";", else: ":"

    env
    |> Enum.find_value(fn {name, value} -> to_string(name) == "NODE_PATH" && value end)
    |> List.wrap()
    |> Enum.flat_map(&String.split(&1, separator))
  end

  defp node_path(_env), do: []

  # -- The migration --------------------------------------------------------

  defp migration(opts) do
    cond do
      not opts[:migration] ->
        :ok

      # Before the dry run, like every other step: a second pass has to say
      # everything is already there, and saying it would run a generator that
      # would not is the one lie a dry run must not tell.
      Enum.any?(Path.wildcard("priv/repo/migrations/*_create_coelho_attachments.exs")) ->
        say(:kept, "priv/repo/migrations", "the attachments migration is already there")

      opts[:dry_run] ->
        say(:todo, "priv/repo/migrations", "run: mix coelho.gen.migration")

      true ->
        file = Mix.Tasks.Coelho.Gen.Migration.run([])
        say(:done, file, "attachments table")
    end
  end

  # -- Editing ---------------------------------------------------------------

  defp insert_at(source, index, line) do
    source
    |> String.split("\n")
    |> List.insert_at(index, line)
    |> Enum.join("\n")
  end

  defp read(path) do
    case File.read(path) do
      {:ok, source} -> {:ok, source}
      {:error, :enoent} -> {:error, "not found — is this an application root?"}
      {:error, reason} -> {:error, "could not be read: #{inspect(reason)}"}
    end
  end

  defp write(path, contents, opts, message) do
    if opts[:dry_run] do
      say(:todo, path, message)
    else
      File.write!(path, contents)
      say(:done, path, message)
    end
  end

  defp say(:done, path, message),
    do: Mix.shell().info([:green, "* wired  ", :reset, path, " — ", message])

  defp say(:kept, path, message),
    do: Mix.shell().info([:cyan, "* kept   ", :reset, path, " — ", message])

  defp say(:todo, path, message),
    do: Mix.shell().info([:yellow, "* yours  ", :reset, path, " — ", message])
end
