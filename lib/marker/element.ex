defmodule Marker.Element do
  @moduledoc """
    This module is responsible for generating element macro's. Marker generates by default all html5 elements,
    but you can easily generate other elements too:

  ```elixir
  defmodule MyElements do
    use Marker.Element, tags: [:my_element, :another_one]
  end
  ```

    You can now use your custom elements like the default elements:

  ```elixir
  use MyElements

  my_element id: 42 do
    another_one "Hello world"
  end
  ```

    Which will result in:

  ```elixir
  {:safe, "<my_element id='42'><another_one>Hello world</another_one></my_element>"}
  ```

  ### Casing

    You can control the casing of the generated elements too:

  ```elixir
  defmodule MyElements do
    use Marker.Element, casing: :camel, tags: [:my_element, :another_one]
  end

  my_element id: 42 do
    another_one "Hello world"
  end

  {:safe, "<myElement id='42'><anotherOne>Hello world</anotherOne></myElement>"}
  ```

  The following casing options are allowed:

    * `:snake` => `my_element` (default)
    * `:snake_upcase` => `MY_ELEMENT`
    * `:pascal` => `MyElement`
    * `:camel` => `myElement`
    * `:lisp` => `my-element`
    * `:lisp_upcase` => `MY-ELEMENT`
  """
  defstruct tag: :div, attrs: [], content: nil

  @type attr_name     :: atom
  @type attr_value    :: Marker.Encoder.t
  @type attrs         :: [{attr_name, attr_value}]

  @type t :: %Marker.Element{tag: atom, content: Marker.content, attrs: attrs}


  @doc false
  defmacro __using__(opts) do
    caller = __CALLER__
    tags = opts[:tags] || []
    tags = Macro.expand(tags, caller)
    casing = opts[:casing] || :snake
    casing = Macro.expand(casing, caller)
    containers = opts[:containers] || [:template, :component]
    containers = Macro.expand(containers, caller)
    functions = Enum.reduce(caller.functions, [], fn {_, fns}, acc -> Keyword.keys(fns) ++ acc end)
    macros = Enum.reduce(caller.macros, [], fn {_, fns}, acc -> Keyword.keys(fns) ++ acc end)
    remove = Keyword.keys(find_ambiguous_imports(tags))
    keys = (functions ++ macros) -- remove
    case opts[:using] do
      false ->
        quote do
          Marker.Element.def_elements(unquote(tags), unquote(keys), unquote(casing))
          Marker.Element.def_container(:_fragment, :fragment)
          Marker.Element.def_containers(unquote(containers))
        end
      _ ->
        quote do
          defmacro __using__(opts) do
            caller = __CALLER__
            ambiguous_imports = Marker.Element.find_ambiguous_imports(unquote(tags))
            quote do
              import Kernel, except: unquote(ambiguous_imports)
              import unquote(__MODULE__)
            end
          end
          Marker.Element.def_elements(unquote(tags), unquote(keys), unquote(casing))
          Marker.Element.def_container(:_fragment, :fragment)
          Marker.Element.def_containers(unquote(containers))
        end
    end
  end

  @doc false
  defmacro def_element(tag, casing) do
    quote bind_quoted: [tag: tag, casing: casing] do
      defmacro unquote(tag)(c1 \\ nil, c2 \\ nil, c3 \\ nil, c4 \\ nil, c5 \\ nil) do
        caller = __CALLER__
        tag = unquote(tag) |> Marker.Element.apply_casing(unquote(casing))
        compiler = Module.get_attribute(caller.module, :marker_compiler) || Marker.Compiler

        %Marker.Element{tag: tag, attrs: [], content: []}
        |> Marker.Element.add_arg(c1, caller)
        |> Marker.Element.add_arg(c2, caller)
        |> Marker.Element.add_arg(c3, caller)
        |> Marker.Element.add_arg(c4, caller)
        |> Marker.Element.add_arg(c5, caller)
        |> compiler.compile()
      end
    end
  end

  @doc false
  defmacro def_elements(tags, keys, casing) do
    quote bind_quoted: [tags: tags, keys: keys, casing: casing] do
      for tag <- tags do
        if not tag in keys do
          Marker.Element.def_element(tag, casing)
        end
      end
    end
  end

  @doc false
  defmacro def_container(tag, fun) do
    quote bind_quoted: [tag: tag, fun: fun] do
      defmacro unquote(fun)(c1 \\ nil, c2 \\ nil, c3 \\ nil, c4 \\ nil, c5 \\ nil) do
        caller = __CALLER__
        compiler = Module.get_attribute(caller.module, :marker_compiler) || Marker.Compiler
        %Marker.Element{tag: unquote(tag), attrs: [], content: []}
        |> Marker.Element.add_arg(c1, caller)
        |> Marker.Element.add_arg(c2, caller)
        |> Marker.Element.add_arg(c3, caller)
        |> Marker.Element.add_arg(c4, caller)
        |> Marker.Element.add_arg(c5, caller)
        |> compiler.compile()
      end
    end
  end

  @doc false
  defmacro def_containers(containers) do
    quote bind_quoted: [containers: containers] do
      for id <- containers do
        name = Atom.to_string(id)
        fun = String.to_atom(name <> "_")
        tag = String.to_atom("_" <> name)
        Marker.Element.def_container(tag, fun)
      end
    end
  end

  @doc """
    sigil ~h is a shortcut to create elements

    not that useful because no other attrs can be added, other than class or id.

    ## Examples

    iex> ~h/input.input-group.form/
    %Marker.Element{
      attrs: [class: :"input-group", class: :form],
      content: nil,
      tag: :input
    }
  """
  defmacro sigil_h({:<<>>, _, [selector]}, _mods) when is_binary(selector) do
    {tag, attrs} = Marker.Element.parse_selector(selector)
    quote do: %Marker.Element{tag: unquote(tag), attrs: unquote(attrs)}
  end

  @doc false
  def apply_casing(tag, :snake) do
    tag
  end
  def apply_casing(tag, :snake_upcase) do
    tag |> Atom.to_string() |> String.upcase() |> String.to_atom()
  end
  def apply_casing(tag, :pascal) do
    tag |> split() |> Enum.map(&String.capitalize/1) |> join()
  end
  def apply_casing(tag, :camel) do
    [first | rest] = split(tag)
    rest = Enum.map(rest, &String.capitalize/1)
    join([first | rest])
  end
  def apply_casing(tag, :lisp) do
    tag |> split() |> join("-")
  end
  def apply_casing(tag, :lisp_upcase) do
    tag |> split() |> Enum.map(&String.upcase/1) |> join("-")
  end

  defp split(tag) do
    tag |> Atom.to_string() |> String.split("_")
  end

  defp join(tokens, joiner \\ "") do
    tokens |> Enum.join(joiner) |> String.to_atom()
  end

  @doc false
  def find_ambiguous_imports(tags, mod \\ Kernel) do
    default_imports = mod.__info__(:functions) ++ mod.__info__(:macros)
    for { name, arity } <- default_imports, arity in 0..2 and name in tags do
      { name, arity }
    end
  end

  # binary selectors were a nice try, but they'll fail for (div "...") or (div "#1"), which isn't really acceptable.
  # so, instead selectors must be defined as a charlist, eg. (div 'input#id.text.lala')
  defguard is_selector(v) when length(v) > 1 and is_integer(hd(v))

  @doc false
  def add_arg(el, content_or_attrs, env) do
    case content_or_attrs do
      nil -> el
      _ ->
        %Marker.Element{tag: tag, attrs: attrs_, content: content_} = el
        content_ = List.wrap(content_)
        {content, attrs} =
          case expand(content_or_attrs, env) do
            attrs when is_selector(attrs)     -> {content_, Keyword.merge(attrs_, selector_attrs(attrs))}
            [{:do, {:__block__, _, content}}] -> {content_ ++ List.wrap(content), attrs_}
            [{:do, content}]                  -> {content_ ++ List.wrap(content), attrs_}
            [{_,_}|_] = attrs                 -> {content_, Keyword.merge(attrs_, attrs)}
            content                           -> {content_ ++ List.wrap(content), attrs_}
          end
        %Marker.Element{tag: tag, content: content, attrs: attrs}
    end
  end

  @doc "parses a selector eg. '.lala#id' into a keyword list"
  def parse_selector(s) do
    binary = to_string(s)
    matches = Regex.split(~r/[\.#]?[a-zA-Z0-9_:-]+/, binary, include_captures: true)
    |> Enum.reject(fn s -> byte_size(s) == 0 end)
    tag = case List.first(matches) do
      "." <> _ -> :div
      "#" <> _ -> :div
      tag -> String.to_atom(tag)
    end
    attrs = Enum.reduce(matches, [], fn i, acc ->
      case i do
        "." <> c -> [{:class, String.to_atom(c)} | acc]
        "#" <> c -> [{:id, String.to_atom(c)} | acc]
        _ -> acc
      end
    end)
    |> :lists.reverse()
    {tag, attrs}
  end

  defp selector_attrs(s) do
    {_, attrs} = parse_selector(s)
    attrs
  end

  defp expand(arg, env) do
    Macro.prewalk(arg, &Macro.expand_once(&1, env))
  end
end

# defmodule Marker.Container do
#   defstruct content: nil, scope: []
# end
