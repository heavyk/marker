defmodule Marker do
  @moduledoc File.read! "README.md"

  @default_elements Marker.HTML
  @default_compiler Marker.Compiler
  @default_transformers &Marker.handle_logic/2

  @type content :: Marker.Encoder.t | [Marker.Encoder.t] | [content]

  @doc "Define a new component"
  defmacro component(name, do: block) when is_atom(name) do
    template = String.to_atom(Atom.to_string(name) <> "__template")
    use_elements = Module.get_attribute(__CALLER__.module, :marker_use_elements) || (quote do: use Marker.HTML)
    transformers = Module.get_attribute(__CALLER__.module, :marker_transformers) || [@default_transformers]
    {block, info} = Enum.reduce(transformers, {block, []}, fn t, {blk, info} -> t.(blk, info) end)
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
        component_ unquote(info), do: content
      end
    end
  end

  @doc "Define a new template"
  defmacro template(name, do: block) when is_atom(name) do
    use_elements = Module.get_attribute(__CALLER__.module, :marker_use_elements) || (quote do: use Marker.HTML)
    transformers = Module.get_attribute(__CALLER__.module, :marker_transformers) || [@default_transformers]
    {block, info} = Enum.reduce(transformers, {block, []}, fn t, {blk, info} -> t.(blk, info) end)
    quote do
      def unquote(name)(var!(assigns) \\ []) do
        unquote(use_elements)
        _ = var!(assigns)
        content = unquote(block)
        template_ unquote(info), do: content
      end
    end
  end

  defmacro __using__(opts) do
    compiler = opts[:compiler] || @default_compiler
    compiler = Macro.expand(compiler, __CALLER__)
    mods = Keyword.get(opts, :elements, @default_elements) |> List.wrap()
    use_elements = for mod <- mods, do: (quote do: use unquote(mod))
    transformers = Keyword.get(opts, :transformers, @default_transformers) |> List.wrap()
    if mod = __CALLER__.module do
      Module.put_attribute(mod, :marker_compiler, compiler)
      Module.put_attribute(mod, :marker_use_elements, use_elements)
      Module.put_attribute(mod, :marker_transformers, transformers)
    end
    quote do
      import Marker, only: [component: 2, template: 2]
      import Marker.Element, only: [sigil_o: 2, sigil_v: 2, sigil_g: 2, sigil_h: 2]
      unquote(use_elements)
    end
  end

  @doc false
  def handle_logic(block, info) do
    # TODO: swap the case for @var! is for js ... instead make ! ended variables the compile-time variables.
    #       will be: @myvar! is for values to be inlined at compile-time. @myvar is just a normal js obv
    # TODO: prewalk the tree, and in the case of convert outer expressions of variables into logic elements
    # IO.puts "handle_logic: #{inspect block}"
    {block, info} = Macro.traverse(block, info, fn
      # PREWALK (going in)
      { :@, meta, [{ name, _, atom }]} = expr, info when is_atom(name) and is_atom(atom) ->
        # static variable to modify how the template is rendered
        name = name |> to_string()
        # IO.puts "@#{name} ->"
        line = Keyword.get(meta, :line, 0)
        cond do
          name |> String.last() == "!" ->
            name = String.trim_trailing(name, "!") |> String.to_atom()
            expr = quote line: line do
              Marker.fetch_assign!(var!(assigns), unquote(name))
            end
            {expr, info}
          true ->
            name = String.to_atom(name)
            assign = quote line: line do
              Access.get(var!(assigns), unquote(name))
            end
            {assign, info}
        end

      expr, info ->
        # IO.puts "prewalk expr: #{inspect expr}"
        {expr, info}
      # END PREWALK
    end, fn
      # POSTWALK (coming back out)
      { sigil, _meta, [{:<<>>, _, [name]}, _]}, info when sigil in [:sigil_o, :sigil_v] ->
        type = case sigil do
          :sigil_v -> :Var
          :sigil_o -> :Obv
        end
        expr =
          {:%, [], [{:__aliases__, [alias: false], [:Marker, :Element, type]}, {:%{}, [], [name: name]}]}
        name = String.to_atom(name)
        info = case t = Keyword.get(info, name) do
          nil -> Keyword.put(info, name, type)
          ^type -> info
          # TODO: better error messages!!
          _ -> raise RuntimeError, "#{name} is a #{t}. it cannot be redefined to be a #{type} in the same template"
        end
        {expr, info}

      { :if, _meta, [left, right]} = expr, info ->
        vars = get_vars(expr)
        cond do
          length(vars) > 0 ->
            do_ = Keyword.get(right, :do)
            else_ = Keyword.get(right, :else, nil)
            test_ = Macro.escape(left)
            expr = quote do: %Marker.Element.If{test: unquote(test_),
                                                  do: unquote(do_),
                                                else: unquote(else_)}
            {expr, info}
          true ->
            {expr, info}
        end
      expr, info ->
        # IO.puts "postwalk expr: #{inspect expr}"
        {expr, info}
      # END postwalk
    end)
    {block, info}
  end
  def handle_logic(block) do
    # shorthand: no scope info
    {block, _info} = handle_logic(block, [])
    block
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

  def get_vars(block) do
    {_, vars} = Macro.postwalk(block, [], fn
      {:%, _, [{:__aliases__, _, [:Marker, :Element, type]}, {:%{}, _, [name: name]}]} = expr, opts when type in [:Obv, :Var] ->
        opts = Keyword.put(opts, String.to_atom(name), type)
        {expr, opts}

      expr, opts ->
        {expr, opts}
    end)
    vars
  end
end
