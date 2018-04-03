defmodule Marker do
  @moduledoc File.read! "README.md"

  @default_elements Marker.HTML
  @default_compiler Marker.Compiler

  @type content :: Marker.Encoder.t | [Marker.Encoder.t] | [content]

  @doc "Define a new component"
  defmacro component(name, do: block) when is_atom(name) do
    use_elements = Module.get_attribute(__CALLER__.module, :marker_use_elements, @default_elements)
    template = String.to_atom(Atom.to_string(name) <> "__template")
    # {block, logic} = Marker.handle_logic(block, [])
    block = Marker.handle_logic(block)
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
    use_elements = Module.get_attribute(__CALLER__.module, :marker_use_elements, @default_elements)
    # {block, logic} = Marker.handle_logic(block, [])
    block = Marker.handle_logic(block)
    quote do
      def unquote(name)(var!(assigns) \\ []) do
        unquote(use_elements)
        _ = var!(assigns)
        content = unquote(block)
        template_ do: content
      end
    end
  end

  @doc "Define a new fragment"
  # defmacro fragment(name, do: block) when is_atom(name) do
  #   use_elements = Module.get_attribute(__CALLER__.module, :marker_use_elements, @default_elements)
  #   # {block, logic} = Marker.handle_logic(block, [])
  #   block = Marker.handle_logic(block)
  #   quote do
  #     def unquote(name)(var!(assigns)) do
  #       unquote(use_elements)
  #       _ = var!(assigns)
  #       fragment do: unquote(block)
  #     end
  #   end
  # end

  defmacro __using__(opts) do
    compiler = opts[:compiler] || @default_compiler
    compiler = Macro.expand(compiler, __CALLER__)
    mods = Keyword.get(opts, :elements, @default_elements)
    use_elements =
      for mod <- List.wrap(mods), do: (quote do: use unquote(mod))
    if mod = __CALLER__.module do
      Module.put_attribute(mod, :marker_compiler, compiler)
      Module.put_attribute(mod, :marker_use_elements, use_elements)
    end
    quote do
      import Marker, only: [component: 2, template: 2]
      unquote(use_elements)
    end
  end

  @doc false
  def handle_logic(block, opts) do
    # TODO: swap the case for @var! is for js ... instead make ! ended variables the compile-time variables.
    #       will be: @myvar! is for values to be inlined at compile-time. @myvar is just a normal js obv
    # TODO: prewalk the tree, and in the case of convert outer expressions of variables into logic elements
    # IO.puts "handle_logic: #{inspect block}"
    {block, _acc} = Macro.traverse(block, opts, fn
    # PREWALK (going in)
      # find variables
      { :@, meta, [{ name, _, atom }]} = expr, opts when is_atom(name) and is_atom(atom) ->
        name = name |> to_string()
        # IO.puts "@#{name} ->"
        cond do
          name |> String.last() == "!" ->
            name = String.trim_trailing(name, "!")
            opts = Keyword.put(opts, :obv, name)
            # IO.puts "found obv: #{name}"
            {expr, opts}
          true ->
            line = Keyword.get(meta, :line, 0)
            chars = name |> to_charlist()
            last = List.last(chars)
            name = chars
            |> List.delete(795)
            |> to_string()
            |> String.to_atom()

            assign =
              if last == 795 do
                quote line: line do
                  Marker.fetch_assign!(var!(assigns), unquote(name))
                end
              else
                quote line: line do
                  Access.get(var!(assigns), unquote(name))
                end
              end
            # IO.puts "(runtime) assigns.#{name} (#{if last == 795, do: "required", else: "optional"})"
            {assign, opts}
        end

      expr, opts ->
        # IO.puts "prewalk expr: #{inspect expr}"
        {expr, opts}
    # END PREWALK
    end, fn
    # POSTWALK (coming back out)
      { :@, _meta, [{ name, _, atom }]} = expr, opts when is_atom(name) and is_atom(atom) ->
        name = name |> to_string()
        # IO.puts "@#{name} <-"
        cond do
          name |> String.last() == "!" ->
            name = String.trim_trailing(name, "!")
            expr = quote do: %Marker.Element.Var{name: unquote(name)}
            # opts = Keyword.delete(opts, :obv, name)
            # IO.puts "@#{name} -> (obv)"
            {expr, opts}
          true ->
            {expr, opts}
        end

      { :if, _meta, [left, right]} = expr, opts -> # when is_atom(test) and is_atom(atom) ->
        # IO.puts "do_logic: #{Keyword.get(opts, :do_logic)}"
        cond do
          Keyword.get(opts, :obv) ->
            do_ = Keyword.get(right, :do)
            else_ = Keyword.get(right, :else, nil)
            test_ = Macro.escape(left)
            # IO.puts "test: #{inspect test_}"
            # IO.puts "do: #{inspect do_}"
            # IO.puts "else: #{inspect else_}"
            expr = quote do: %Marker.Element.If{test: unquote(test_),
                                                  do: unquote(do_),
                                                else: unquote(else_)}
            {expr, opts}
          true ->
            {expr, opts}
        end
      expr, opts ->
        # IO.puts "postwalk expr: #{inspect expr}"
        {expr, opts}
    # END postwalk
    end)
    {block, opts}
  end
  def handle_logic(block) do
    {block, _opts} = handle_logic(block, [])
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
end
