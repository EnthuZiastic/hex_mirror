defmodule HexMirrorWeb.PackagesLive do
  use HexMirrorWeb, :live_view

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    packages = HexMirror.Mirror.local_packages()
    {:ok, assign(socket, query: "", all: packages, packages: packages)}
  end

  @impl Phoenix.LiveView
  def handle_event("filter", %{"q" => query}, socket) do
    filtered =
      case String.trim(query) do
        "" -> socket.assigns.all
        needle -> Enum.filter(socket.assigns.all, &String.contains?(&1, needle))
      end

    {:noreply, assign(socket, query: query, packages: filtered)}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <h1>Packages ({length(@all)})</h1>
    <form phx-change="filter">
      <input type="search" name="q" value={@query} placeholder="filter packages…" autofocus />
    </form>
    <ul>
      <li :for={name <- @packages}>{name}</li>
    </ul>
    """
  end
end
