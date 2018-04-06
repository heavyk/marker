defmodule Marker do
  @moduledoc File.read! "README.md"

  @default_elements Marker.HTML
  @default_compiler Marker.Compiler
  @default_imports [component: 2, template: 2]
  @default_transformers &Marker.handle_assigns/2

  @type content :: Marker.Encoder.t | [Marker.Encoder.t] | [content]

  @doc "Define a new component"
  defmacro component(name, do: block) when is_atom(name) do
    template = String.to_atom(Atom.to_string(name) <> "__template")
    use_elements = Module.get_attribute(__CALLER__.module, :marker_use_elements) || (quote do: use Marker.HTML)
    block = Marker.handle_assigns(block, true)
    quote do
      defmacro unquote(name)(content_or_attrs \\ nil, maybe_content \\ nil) do
        { attrs, content } = Marker.Element.normalize_args(content_or_attrs, maybe_content, __CALLER__)
        content = quote do: List.wrap(unquote(content))
        assigns = {:%{}, [], [{:__content__, content} | attrs]}
        template = unquote(template)
        quote do
          unquote(__MODULE__).unquote(template)(unquote(assigns))
        end
      end
      @doc false
      def unquote(template)(var!(assigns)) do
        unquote(use_elements)
        _ = var!(assigns)
        content = unquote(block)
        component_ do: content
      end
    end
  end

  @doc "Define a new template"
  defmacro template(name, do: block) when is_atom(name) do
    use_elements = Module.get_attribute(__CALLER__.module, :marker_use_elements) || (quote do: use Marker.HTML)
    block = Marker.handle_assigns(block, false)
    quote do
      def unquote(name)(var!(assigns) \\ []) do
        unquote(use_elements)
        _ = var!(assigns)
        content = unquote(block)
        template_ do: content
      end
    end
  end

  defmacro __using__(opts) do
    imports = opts[:imports] || @default_imports
    imports = Macro.expand(imports, __CALLER__)
    compiler = opts[:compiler] || @default_compiler
    compiler = Macro.expand(compiler, __CALLER__)
    mods = Keyword.get(opts, :elements, @default_elements) |> List.wrap()
    use_elements = for mod <- mods, do: (quote do: use unquote(mod))
    transformers = Keyword.get(opts, :transformers, @default_transformers) |> List.wrap()
    mod = __CALLER__.module
    Module.put_attribute(mod, :marker_compiler, compiler)
    Module.put_attribute(mod, :marker_use_elements, use_elements)
    Module.put_attribute(mod, :marker_transformers, transformers)
    # imports = Enum.reduce(mods, imports, fn mod, imports ->
    #   mod = Macro.expand(mod, __CALLER__)
    #   IO.puts "mod: #{inspect mod}"
    #   containers = Module.get_attribute(mod, :containers)
    #   imports = Keyword.delete(imports, containers)
    # end)
    functions = Enum.reduce(__CALLER__.functions, [], fn {_, fns}, acc -> Keyword.keys(fns) ++ acc end)
    macros = Enum.reduce(__CALLER__.macros, [], fn {_, fns}, acc -> Keyword.keys(fns) ++ acc end)
    imports = imports
    |> Keyword.drop(functions)
    |> Keyword.drop(macros)
    # IO.inspect opts, label: "opts"
    # IO.inspect imports, label: "imports #{inspect __CALLER__.module}"
    # IO.inspect :template in functions ++ macros, label: "container in"
    quote do
      import Marker, only: unquote(imports)
      # import Marker.Element, only: [sigil_o: 2, sigil_v: 2, sigil_g: 2, sigil_h: 2]
      unquote(use_elements)
    end
  end

  @doc false
  def handle_assigns(block, allow_optional) do
    Macro.prewalk(block, fn
      { :@, meta, [{ name, _, atom }]} when is_atom(name) and is_atom(atom) ->
        line = Keyword.get(meta, :line, 0)
        str = to_string(name)
        cond do
          String.last(str) == "!" or allow_optional == false ->
            name = str
            |> String.trim_trailing("!")
            |> String.to_atom()
            quote line: line do
              Marker.fetch_assign!(var!(assigns), unquote(name))
            end

          true ->
            quote line: line do
              Access.get(var!(assigns), unquote(name))
            end
        end
      expr ->
        expr
    end)
  end

  @doc false
  def fetch_assign!(assigns, key) do
    case Access.fetch(assigns, key) do
      {:ok, val} ->
        val
      :error ->
        # TODO: we need to use this, and when the variable does not exist, perhaps catch the error and transform into a %Marker.Element.If{}
        keys = Enum.map(assigns, &elem(&1, 0))
        raise "assign @#{key} not available in Marker template. " <>
          "Please ensure all assigns are given as options. " <>
          "Available assigns: #{inspect keys}"
    end
  end
end
